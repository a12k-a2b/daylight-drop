package com.daylight.drop

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.view.WindowManager
import android.widget.Toast
import com.daylight.drop.transport.AndroidHttpClient
import com.daylight.drop.transport.LoopSuppressionEngine
import com.daylight.drop.transport.ProtocolConstants
import com.daylight.drop.transport.TextPayload
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * ShareActivity: Direct Share sheet target handling Intent.ACTION_SEND and ACTION_SEND_MULTIPLE.
 *
 * Requirements:
 * 1. Handles text, URLs, screenshots, images, PDFs, notes, and arbitrary files shared
 *    from any Android app via the system Chooser sheet.
 * 2. Window is styled with Theme.Daylight.TranslucentTrampoline to eliminate UI flicker.
 * 3. Extracts payload immediately, dispatches network transfers in background applicationScope,
 *    shows an immediate Sol:OS HUD toast, and finishes with overridePendingTransition(0, 0)
 *    within <50ms so user returns to source app immediately.
 */
class ShareActivity : Activity() {

    companion object {
        private const val TAG = "ShareActivity"
        const val EXTRA_TARGET_DEVICE = "target_device"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Make window translucent with zero dim
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)

        handleIncomingShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        if (intent != null) {
            handleIncomingShareIntent(intent)
        }
    }

    data class StagedShare(val file: File, val dropType: String, val displayName: String)

    /**
     * Inspects the incoming share intent and dispatches text or files to Mac.
     */
    private fun handleIncomingShareIntent(intent: Intent) {
        val action = intent.action
        val type = intent.type

        Log.i(TAG, "Handling share intent action=$action, type=$type")

        when (action) {
            Intent.ACTION_SEND -> {
                var handledAny = false
                if (intent.hasExtra(Intent.EXTRA_STREAM)) {
                    @Suppress("DEPRECATION")
                    val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM)
                    }

                    if (uri != null) {
                        val staged = stageUrisSynchronously(listOf(uri))
                        if (staged.isNotEmpty()) {
                            dispatchStagedSharesAsync(staged)
                            handledAny = true
                        }
                    }
                }

                if (intent.hasExtra(Intent.EXTRA_TEXT)) {
                    val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (!sharedText.isNullOrEmpty()) {
                        shareTextAsync(sharedText)
                        handledAny = true
                    }
                }

                if (!handledAny) {
                    showSolToast(getString(R.string.toast_share_empty))
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                }

                if (!uris.isNullOrEmpty()) {
                    val staged = stageUrisSynchronously(uris)
                    if (staged.isNotEmpty()) {
                        dispatchStagedSharesAsync(staged)
                    } else {
                        showSolToast(getString(R.string.toast_share_empty))
                    }
                } else {
                    showSolToast(getString(R.string.toast_share_empty))
                }
            }
            else -> {
                Log.w(TAG, "Unsupported share action: $action")
            }
        }

        // Return user to their app with zero flicker
        finishWithZeroAnimation()
    }

    /**
     * Copies streams synchronously to cacheDir while URI permissions remain valid.
     */
    private fun stageUrisSynchronously(uris: List<Uri>): List<StagedShare> {
        val result = mutableListOf<StagedShare>()
        val context = applicationContext
        for (uri in uris) {
            try {
                val displayName = resolveFilename(context, uri) ?: "share_${System.currentTimeMillis()}"
                val tempFile = File(context.cacheDir, "direct_share_${UUID.randomUUID()}_$displayName")

                context.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(tempFile).use { output ->
                        input.copyTo(output)
                    }
                }

                if (tempFile.exists() && tempFile.length() > 0) {
                    val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
                    val dropType = when {
                        mimeType.startsWith("image/") -> "image"
                        mimeType.contains("pdf") -> "document"
                        else -> "file"
                    }
                    result.add(StagedShare(tempFile, dropType, displayName))
                } else {
                    tempFile.delete()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed staging URI synchronously: $uri", e)
            }
        }
        return result
    }

    /**
     * Beams shared text or URL to Mac via AndroidHttpClient.
     */
    private fun shareTextAsync(text: String) {
        showSolToast(getString(R.string.toast_sharing_to_mac))

        val sha256 = LoopSuppressionEngine.computeSha256(text)
        PeerTargetManager.loopSuppression.recordHash(sha256)

        val payload = TextPayload(
            id = UUID.randomUUID().toString(),
            type = "prompt",
            text = text,
            origin = PeerTargetManager.getLocalDeviceId(),
            timestamp = System.currentTimeMillis()
        )

        PeerTargetManager.applicationScope.launch(Dispatchers.IO) {
            try {
                PeerTargetManager.sendTextToMac(payload)
                TransferHistoryManager.recordSent(
                    filename = "shared_text_${System.currentTimeMillis()}.txt",
                    fileSize = text.toByteArray().size.toLong(),
                    type = "text",
                    previewText = text
                )
                Log.i(TAG, "Direct shared text beamed successfully to Mac")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to beam direct shared text to Mac", e)
            }
        }
    }

    /**
     * Beams one or more staged files to Mac via AndroidHttpClient.sendDrop().
     */
    private fun dispatchStagedSharesAsync(staged: List<StagedShare>) {
        val count = staged.size
        val message = if (count == 1) {
            getString(R.string.toast_sharing_file_to_mac)
        } else {
            getString(R.string.toast_sharing_files_to_mac, count)
        }
        showSolToast(message)

        PeerTargetManager.applicationScope.launch(Dispatchers.IO) {
            for (item in staged) {
                try {
                    val fileSize = item.file.length()
                    PeerTargetManager.sendDropToMac(
                        file = item.file,
                        type = item.dropType,
                        origin = PeerTargetManager.getLocalDeviceId(),
                        customFilename = item.displayName
                    )
                    TransferHistoryManager.recordSent(
                        filename = item.displayName,
                        fileSize = fileSize,
                        type = item.dropType
                    )
                    Log.i(TAG, "Direct shared file beamed: ${item.displayName} (${item.dropType})")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed beaming shared file: ${item.displayName}", e)
                } finally {
                    item.file.delete()
                }
            }
        }
    }

    private fun resolveFilename(context: Context, uri: Uri): String? {
        if (uri.scheme == "content") {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx != -1) return cursor.getString(idx)
                }
            }
        }
        return uri.lastPathSegment
    }

    private fun showSolToast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
    }

    private fun finishWithZeroAnimation() {
        finish()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            overrideActivityTransition(Activity.OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }
}
