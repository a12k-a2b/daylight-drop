package com.daylight.drop

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
import java.util.concurrent.atomic.AtomicBoolean

/**
 * BeamTrampolineActivity: Ephemeral translucent window (<25ms focus) overcoming
 * Android 13 background clipboard restriction.
 *
 * Flow:
 * 1. Launched via startActivityAndCollapse() from DropTileService or internal shortcut.
 * 2. Window is fully translucent with @style/Theme.Daylight.TranslucentTrampoline (zero dim, zero animation).
 * 3. On gaining window focus in onWindowFocusChanged(true):
 *    - Reads ClipboardManager.getPrimaryClip().
 *    - Checks 3-tier loop suppression (ClipDescription origin tag + SHA-256 LRU cache).
 *    - If from Mac or duplicate, suppresses outbound echo.
 *    - If valid, dispatches payload asynchronously via application scope (preventing coroutine
 *      cancellation on activity finish).
 *    - Beams via AndroidHttpClient to port 8765 (USB reverse tunnel 127.0.0.1 or Wi-Fi LAN).
 *    - Displays Sol:OS HUD toast.
 *    - Immediately calls finish() with overridePendingTransition(0, 0).
 */
class BeamTrampolineActivity : Activity() {

    companion object {
        private const val TAG = "BeamTrampoline"
        const val EXTRA_TRIGGER_SOURCE = "extra_trigger_source"
        private const val SAFETY_TIMEOUT_MS = 600L
    }

    private val hasProcessed = AtomicBoolean(false)
    private val safetyHandler = Handler(Looper.getMainLooper())
    private val safetyRunnable = Runnable {
        if (!isFinishing && !isDestroyed) {
            Log.w(TAG, "Safety timeout reached before focus change — finishing activity")
            finishWithZeroAnimation()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Ensure window is completely transparent without background dimming
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)

        // Safety watchdog: ensure activity never hangs open even if window focus is deferred
        safetyHandler.postDelayed(safetyRunnable, SAFETY_TIMEOUT_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && hasProcessed.compareAndSet(false, true)) {
            safetyHandler.removeCallbacks(safetyRunnable)
            processAndBeamClipboard()
        }
    }

    override fun onDestroy() {
        safetyHandler.removeCallbacks(safetyRunnable)
        super.onDestroy()
    }

    /**
     * Reads the system clipboard now that window focus is legitimately acquired,
     * checks loop suppression, and dispatches to Mac.
     */
    private fun processAndBeamClipboard() {
        val startTime = System.currentTimeMillis()
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val clip = clipboard?.primaryClip

        if (clip == null || clip.itemCount == 0) {
            Log.i(TAG, "Clipboard is empty")
            showSolToast(getString(R.string.toast_clipboard_empty))
            finishWithZeroAnimation()
            return
        }

        // Tier 2 Loop Suppression: ClipDescription Origin Check
        val originTag = clip.description.extras?.getString(ProtocolConstants.ORIGIN_TAG)
        val isMacOrigin = originTag != null && (
            originTag == ProtocolConstants.ROLE_MAC ||
            originTag == PeerTargetManager.getMacDeviceId() ||
            originTag.startsWith("mac") ||
            originTag != PeerTargetManager.getLocalDeviceId()
        )
        if (isMacOrigin) {
            Log.i(TAG, "Suppressed echoing clipboard originating from Mac: $originTag")
            showSolToast(getString(R.string.toast_clipboard_loop_suppressed))
            finishWithZeroAnimation()
            return
        }

        val item = clip.getItemAt(0)
        val uri = item.uri
        val text = item.text?.toString() ?: item.coerceToText(this)?.toString()

        if (uri != null) {
            val staged = stageClipboardUriSynchronously(uri)
            if (staged != null) {
                beamStagedClipAsync(staged)
            } else {
                showSolToast(getString(R.string.toast_clipboard_unsupported))
            }
        } else if (!text.isNullOrEmpty()) {
            beamTextAsync(text)
        } else {
            Log.w(TAG, "Clipboard item contains neither text nor URI")
            showSolToast(getString(R.string.toast_clipboard_unsupported))
            finishWithZeroAnimation()
            return
        }

        val focusDuration = System.currentTimeMillis() - startTime
        Log.i(TAG, "Clipboard processing completed in ${focusDuration}ms — finishing trampoline")
        finishWithZeroAnimation()
    }

    /**
     * Beams text payload to Mac via AndroidHttpClient.
     * Uses application-level CoroutineScope so the network call survives activity dismissal.
     */
    private fun beamTextAsync(text: String) {
        // Tier 3 Loop Suppression: SHA-256 LRU Cache Check
        val sha256 = LoopSuppressionEngine.computeSha256(text)
        if (PeerTargetManager.loopSuppression.shouldSuppressHash(sha256)) {
            Log.i(TAG, "Suppressed duplicate clipboard text via SHA-256 LRU cache: $sha256")
            showSolToast(getString(R.string.toast_clipboard_duplicate_suppressed))
            return
        }

        // Record outgoing hash in LRU cache to suppress loopback
        PeerTargetManager.loopSuppression.recordHash(sha256)
        showSolToast(getString(R.string.toast_beaming_clipboard))

        val localDeviceId = PeerTargetManager.getLocalDeviceId()
        val payload = TextPayload(
            id = UUID.randomUUID().toString(),
            type = "clipboard",
            text = text,
            origin = localDeviceId,
            timestamp = System.currentTimeMillis()
        )

        PeerTargetManager.applicationScope.launch(Dispatchers.IO) {
            DaylightDropService.acquireWakeLock(60_000L)
            try {
                val client = PeerTargetManager.httpClient
                val host = PeerTargetManager.getActiveHost()
                val port = ProtocolConstants.MAC_PORT
                Log.i(TAG, "Beaming clipboard text (${text.length} chars) to http://$host:$port")
                val response = client.sendText(payload, targetHost = host, targetPort = port)
                Log.i(TAG, "Beamed clipboard successfully: $response")
            } catch (e: Exception) {
                Log.e(TAG, "Failed beaming clipboard text to active host, trying USB loopback fallback", e)
                tryFallbackUsb(payload)
            } finally {
                DaylightDropService.releaseWakeLock()
            }
        }
    }

    /**
     * Fallback to 127.0.0.1:8765 if Wi-Fi transmission failed.
     */
    private fun tryFallbackUsb(payload: TextPayload) {
        PeerTargetManager.applicationScope.launch(Dispatchers.IO) {
            DaylightDropService.acquireWakeLock(60_000L)
            try {
                val client = PeerTargetManager.httpClient
                client.sendText(payload, targetHost = "127.0.0.1", targetPort = ProtocolConstants.MAC_PORT)
                Log.i(TAG, "Fallback USB beam succeeded for clipboard text")
            } catch (e: Exception) {
                Log.e(TAG, "Both Wi-Fi and USB fallback failed for clipboard beam", e)
            } finally {
                DaylightDropService.releaseWakeLock()
            }
        }
    }

    data class StagedClip(val file: File, val type: String, val filename: String)

    private fun stageClipboardUriSynchronously(uri: Uri): StagedClip? {
        val context = applicationContext
        return try {
            val filename = resolveFilename(context, uri) ?: "clipboard_${System.currentTimeMillis()}"
            val tempFile = File(context.cacheDir, "drop_clip_${UUID.randomUUID()}_$filename")
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(tempFile).use { output ->
                    input.copyTo(output)
                }
            }
            if (tempFile.exists() && tempFile.length() > 0) {
                val type = if (context.contentResolver.getType(uri)?.startsWith("image/") == true) "image" else "document"
                StagedClip(tempFile, type, filename)
            } else {
                tempFile.delete()
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed staging clipboard URI synchronously", e)
            null
        }
    }

    /**
     * Beams URI/image payload to Mac via AndroidHttpClient.sendDrop().
     */
    private fun beamStagedClipAsync(staged: StagedClip) {
        showSolToast(getString(R.string.toast_beaming_file))

        PeerTargetManager.applicationScope.launch(Dispatchers.IO) {
            DaylightDropService.acquireWakeLock(60_000L)
            try {
                val host = PeerTargetManager.getActiveHost()
                val port = ProtocolConstants.MAC_PORT

                PeerTargetManager.httpClient.sendDrop(
                    file = staged.file,
                    type = staged.type,
                    origin = PeerTargetManager.getLocalDeviceId(),
                    targetHost = host,
                    targetPort = port
                )
                Log.i(TAG, "Beamed clipboard URI successfully: ${staged.filename}")
            } catch (e: Exception) {
                Log.e(TAG, "Failed beaming clipboard URI", e)
            } finally {
                staged.file.delete()
                DaylightDropService.releaseWakeLock()
            }
        }
    }

    private fun resolveFilename(context: Context, uri: Uri): String? {
        if (uri.scheme == "content") {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex != -1) return cursor.getString(nameIndex)
                }
            }
        }
        return uri.lastPathSegment
    }

    /**
     * Displays a clean Sol:OS styled toast message.
     */
    private fun showSolToast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
    }

    /**
     * Finishes the trampoline activity immediately with zero transition animations,
     * ensuring fluid LivePaper rendering with 0ms visual flicker.
     */
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
