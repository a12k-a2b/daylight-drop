package com.daylight.drop

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import com.daylight.drop.transport.AndroidChannelType
import com.daylight.drop.transport.ProtocolConstants
import com.google.android.material.card.MaterialCardView
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private const val TAG = "DaylightDropMain"

enum class StreamTab {
    RECEIVED, // From Mac
    SENT      // To Mac
}

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

    // Two-sided Stream Tabs
    private lateinit var btnTabReceived: Button
    private lateinit var btnTabSent: Button
    private var currentTab = StreamTab.RECEIVED

    // Code Block elements
    private lateinit var layoutCodeBlock: LinearLayout
    private lateinit var tvCodeBlock: TextView
    private lateinit var btnCopyCode: Button

    // Dynamic files list
    private lateinit var layoutRecentFilesContainer: LinearLayout

    private val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Initialize managers
        PeerTargetManager.init(applicationContext)
        TransferHistoryManager.init(applicationContext)

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

        btnTabReceived = findViewById(R.id.btnTabReceived)
        btnTabSent = findViewById(R.id.btnTabSent)

        layoutCodeBlock = findViewById(R.id.layoutCodeBlock)
        tvCodeBlock = findViewById(R.id.tvCodeBlock)
        btnCopyCode = findViewById(R.id.btnCopyCode)

        layoutRecentFilesContainer = findViewById(R.id.layoutRecentFilesContainer)
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

        btnTabReceived.setOnClickListener {
            if (currentTab != StreamTab.RECEIVED) {
                currentTab = StreamTab.RECEIVED
                updateTabStyles()
                refreshRecentDrops()
            }
        }

        btnTabSent.setOnClickListener {
            if (currentTab != StreamTab.SENT) {
                currentTab = StreamTab.SENT
                updateTabStyles()
                refreshRecentDrops()
            }
        }

        btnCopyCode.setOnClickListener {
            val text = tvCodeBlock.text.toString()
            if (text.isNotEmpty()) {
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                val clip = ClipData.newPlainText("Daylight Drop Text", text)
                clipboard?.setPrimaryClip(clip)
                btnCopyCode.text = "Copied!"
                btnCopyCode.postDelayed({ btnCopyCode.text = "Copy" }, 1500)
                Toast.makeText(this, "Copied to clipboard", Toast.LENGTH_SHORT).show()
            }
        }

        PeerTargetManager.onTextUpdated = { text ->
            runOnUiThread {
                displayReceivedText(text)
            }
        }

        PeerTargetManager.onTransfersUpdated = {
            runOnUiThread {
                refreshRecentDrops()
            }
        }

        TransferHistoryManager.onHistoryChanged = {
            runOnUiThread {
                refreshRecentDrops()
            }
        }
    }

    private fun updateTabStyles() {
        if (currentTab == StreamTab.RECEIVED) {
            btnTabReceived.setBackgroundColor(getColor(R.color.os_900))
            btnTabReceived.setTextColor(getColor(R.color.os_0))
            btnTabSent.setBackgroundColor(getColor(R.color.os_150))
            btnTabSent.setTextColor(getColor(R.color.os_800))
        } else {
            btnTabSent.setBackgroundColor(getColor(R.color.os_900))
            btnTabSent.setTextColor(getColor(R.color.os_0))
            btnTabReceived.setBackgroundColor(getColor(R.color.os_150))
            btnTabReceived.setTextColor(getColor(R.color.os_800))
        }
    }

    private fun displayReceivedText(text: String) {
        if (text.trim().isNotEmpty()) {
            tvCodeBlock.text = text
            layoutCodeBlock.visibility = View.VISIBLE
        } else {
            layoutCodeBlock.visibility = View.GONE
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

        // 1. Check for latest text / prompt
        val inMemoryText = PeerTargetManager.latestReceivedText
        if (!inMemoryText.isNullOrEmpty()) {
            displayReceivedText(inMemoryText)
        } else {
            val latestPromptFile = incomingDir.listFiles()?.filter {
                it.name.startsWith("prompt_") || it.name.startsWith("note_")
            }?.maxByOrNull { it.lastModified() }

            if (latestPromptFile != null && latestPromptFile.exists()) {
                val text = try { latestPromptFile.readText() } catch (_: Exception) { "" }
                if (text.isNotEmpty()) {
                    displayReceivedText(text)
                } else {
                    layoutCodeBlock.visibility = View.GONE
                }
            } else {
                layoutCodeBlock.visibility = View.GONE
            }
        }

        // 2. Fetch Two-Sided Streams
        val receivedItems = TransferHistoryManager.getReceivedItems()
        val sentItems = TransferHistoryManager.getSentItems()

        // Update Tab Titles with Counts
        btnTabReceived.text = "From Mac (${receivedItems.size})"
        btnTabSent.text = "To Mac (${sentItems.size})"
        updateTabStyles()

        val activeItems = if (currentTab == StreamTab.RECEIVED) receivedItems else sentItems

        layoutRecentFilesContainer.removeAllViews()

        if (activeItems.isEmpty()) {
            tvRecentItems.visibility = View.VISIBLE
            tvRecentItems.text = if (currentTab == StreamTab.RECEIVED) {
                "No files received from Mac yet. Drop files or prompts from Mac tray."
            } else {
                "No files sent to Mac yet. Take a screenshot or share via Share Sheet."
            }
        } else {
            tvRecentItems.visibility = View.GONE
            val inflater = LayoutInflater.from(this)

            for (record in activeItems) {
                val itemView = inflater.inflate(R.layout.item_recent_file, layoutRecentFilesContainer, false)
                val card = itemView.findViewById<MaterialCardView>(R.id.cardRecentFile)
                val tvName = itemView.findViewById<TextView>(R.id.tvFileName)
                val tvDetails = itemView.findViewById<TextView>(R.id.tvFileDetails)
                val tvSnippetLine = itemView.findViewById<TextView>(R.id.tvSnippetLine)

                val ivThumbnail = itemView.findViewById<ImageView>(R.id.ivFileThumbnail)
                val tvSnippetPreview = itemView.findViewById<TextView>(R.id.tvSnippetPreview)
                val ivIcon = itemView.findViewById<ImageView>(R.id.ivFileIcon)

                val btnOpen = itemView.findViewById<Button>(R.id.btnOpenFile)
                val btnCopy = itemView.findViewById<Button>(R.id.btnCopyFile)
                val btnShare = itemView.findViewById<Button>(R.id.btnShareFile)

                val file = record.file
                tvName.text = record.filename
                val timeStr = timeFormat.format(Date(record.timestamp))
                val directionTag = if (record.isOutbound) "To Mac" else "From Mac"
                tvDetails.text = "${formatBytes(record.size)} • $timeStr • $directionTag"

                // Show snippet line if present
                if (!record.previewText.isNullOrEmpty()) {
                    val oneLiner = record.previewText.replace("\n", " ").trim()
                    tvSnippetLine.text = oneLiner
                    tvSnippetLine.visibility = View.VISIBLE
                } else {
                    tvSnippetLine.visibility = View.GONE
                }

                // Thumbnail & Preview Resolution
                val ext = file.extension.lowercase(Locale.US)
                val isImage = ext in listOf("png", "jpg", "jpeg", "webp", "heic", "heif")
                val isPdf = ext == "pdf"
                val isText = ext in listOf("md", "txt", "json", "py", "kt", "xml", "csv")

                if (isImage || isPdf) {
                    ThumbnailHelper.loadThumbnail(
                        context = this,
                        file = file,
                        imageView = ivThumbnail,
                        targetWidth = 144,
                        targetHeight = 144,
                        scope = lifecycleScope,
                        onSuccess = {
                            ivThumbnail.visibility = View.VISIBLE
                            tvSnippetPreview.visibility = View.GONE
                            ivIcon.visibility = View.GONE
                        },
                        onFallback = {
                            ivThumbnail.visibility = View.GONE
                            tvSnippetPreview.visibility = View.GONE
                            ivIcon.visibility = View.VISIBLE
                            ivIcon.setImageResource(if (isImage) android.R.drawable.ic_menu_gallery else R.drawable.ic_drop_file)
                        }
                    )
                } else if (isText) {
                    ivThumbnail.visibility = View.GONE
                    val previewText = record.previewText ?: try {
                        file.bufferedReader().useLines { lines -> lines.take(4).joinToString("\n") }
                    } catch (_: Exception) { "" }

                    if (previewText.isNotEmpty()) {
                        tvSnippetPreview.text = previewText
                        tvSnippetPreview.visibility = View.VISIBLE
                        ivIcon.visibility = View.GONE
                    } else {
                        tvSnippetPreview.visibility = View.GONE
                        ivIcon.visibility = View.VISIBLE
                        ivIcon.setImageResource(R.drawable.ic_drop_prompt)
                    }
                } else {
                    ivThumbnail.visibility = View.GONE
                    tvSnippetPreview.visibility = View.GONE
                    ivIcon.visibility = View.VISIBLE
                    ivIcon.setImageResource(R.drawable.ic_drop_file)
                }

                // 1. Open Button & Card Tap
                val openClickListener = View.OnClickListener {
                    Log.i(TAG, "Opening file: ${file.name}")
                    openFile(file)
                }
                card.setOnClickListener(openClickListener)
                btnOpen.setOnClickListener(openClickListener)

                // 2. Copy Button
                btnCopy.setOnClickListener {
                    copyFileToClipboard(record, btnCopy)
                }

                // 3. Share Button
                btnShare.setOnClickListener {
                    shareFile(file)
                }

                layoutRecentFilesContainer.addView(itemView)
            }
        }
    }

    private fun copyFileToClipboard(record: TransferRecord, button: Button) {
        val file = record.file
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val ext = file.extension.lowercase(Locale.US)

        try {
            if (ext in listOf("md", "txt", "json", "py", "kt", "xml", "csv") || record.transferType in listOf("prompt", "clipboard", "note")) {
                val text = if (!record.previewText.isNullOrEmpty() && file.length() < 100_000) {
                    try { file.readText() } catch (_: Exception) { record.previewText }
                } else {
                    try { file.readText() } catch (_: Exception) { file.name }
                }
                val clip = ClipData.newPlainText(file.name, text)
                clipboard?.setPrimaryClip(clip)
            } else {
                val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
                val mimeType = getMimeType(file)
                val clip = ClipData.newUri(contentResolver, file.name, uri)
                clipboard?.setPrimaryClip(clip)
            }

            button.text = "Copied!"
            button.postDelayed({ button.text = "Copy" }, 1500)
            Toast.makeText(this, "Copied ${file.name} to clipboard", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to copy file to clipboard: ${file.name}", e)
            Toast.makeText(this, "Failed to copy to clipboard", Toast.LENGTH_SHORT).show()
        }
    }

    private fun shareFile(file: File) {
        try {
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val mimeType = getMimeType(file)
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(shareIntent, "Share ${file.name}"))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initiate share sheet for ${file.name}", e)
            Toast.makeText(this, "Failed to open share sheet: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun openFile(file: File) {
        try {
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val mimeType = getMimeType(file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(intent, "Open with"))
        } catch (e: Exception) {
            Log.w(TAG, "FileProvider intent failed, trying direct intent: ${e.message}")
            try {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    val rawUri = Uri.fromFile(file)
                    setDataAndType(rawUri, getMimeType(file))
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "Failed to open file: ${file.name}", e2)
                Toast.makeText(this, "No application found to open ${file.name}", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun getMimeType(file: File): String {
        return when (file.extension.lowercase(Locale.US)) {
            "md", "markdown" -> "text/plain"
            "txt" -> "text/plain"
            "pdf" -> "application/pdf"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "heic" -> "image/heic"
            "heif" -> "image/heif"
            "json" -> "application/json"
            "html" -> "text/html"
            else -> "*/*"
        }
    }

    private fun openStorageDirectory() {
        val incomingDir = File(ProtocolConstants.DEFAULT_ANDROID_INCOMING)
        val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", incomingDir)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "resource/folder")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "No default folder viewer found: ${e.message}")
            val fallbackIntent = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "*/*"
            }
            try {
                startActivity(fallbackIntent)
            } catch (e2: Exception) {
                Toast.makeText(this, "Storage location: ${incomingDir.absolutePath}", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB")
        val digitGroups = (Math.log10(bytes.toDouble()) / Math.log10(1024.0)).toInt()
        val index = digitGroups.coerceIn(0, units.size - 1)
        return "%.1f %s".format(Locale.US, bytes / Math.pow(1024.0, index.toDouble()), units[index])
    }
}
