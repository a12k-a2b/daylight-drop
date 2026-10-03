package com.daylight.drop

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.os.PersistableBundle
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import com.daylight.drop.transport.LoopSuppressionEngine
import com.daylight.drop.transport.ProtocolConstants
import com.daylight.drop.transport.TextPayload
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale

private const val TAG = "DaylightDropInbound"

/**
 * Handles inbound files and text/prompts received from Mac.
 * Stages files into /sdcard/Download/DaylightDrop/ with atomic rename, SHA-256 validation,
 * immediate MediaScannerConnection indexing, clipboard updates, and Sol:OS heads-up banner.
 */
class InboundStorageManager(
    private val context: Context,
    val loopSuppression: LoopSuppressionEngine,
    val incomingDir: File = File(ProtocolConstants.DEFAULT_ANDROID_INCOMING),
    private val scope: CoroutineScope
) {

    var onItemIndexed: ((path: String, uri: String?) -> Unit)? = null
    var onPromptReceived: ((TextPayload) -> Unit)? = null

    init {
        if (!incomingDir.exists()) {
            incomingDir.mkdirs()
        }
        cleanupStaleTempFiles()
    }

    /**
     * Handles an incoming raw stream from HTTP drop post.
     */
    @Throws(IOException::class)
    fun saveInboundStream(
        transferId: String,
        desiredFilename: String,
        dropType: String,
        expectedSha256: String?,
        origin: String,
        input: InputStream,
        contentLength: Long
    ): File {
        if (!incomingDir.exists()) {
            incomingDir.mkdirs()
        }

        val sanitized = sanitizeFilename(desiredFilename)
        val tempFile = File(incomingDir, "${ProtocolConstants.TEMP_PREFIX}${transferId}_${sanitized}${ProtocolConstants.PART_SUFFIX}")
        if (tempFile.exists()) tempFile.delete()

        val digest = MessageDigest.getInstance("SHA-256")
        var bytesWritten = 0L

        try {
            FileOutputStream(tempFile).use { fos ->
                val buffer = ByteArray(64 * 1024)
                var read: Int
                while (bytesWritten < contentLength || contentLength < 0) {
                    val toRead = if (contentLength > 0) {
                        minOf(buffer.size.toLong(), contentLength - bytesWritten).toInt()
                    } else buffer.size

                    read = input.read(buffer, 0, toRead)
                    if (read == -1) break
                    fos.write(buffer, 0, read)
                    digest.update(buffer, 0, read)
                    bytesWritten += read

                    if (contentLength > 0 && bytesWritten >= contentLength) break
                }
                fos.fd.sync() // POSIX fsync flush
            }
        } catch (e: Exception) {
            tempFile.delete()
            throw IOException("Failed to write inbound stream for $sanitized: ${e.message}", e)
        }

        val computedHash = digest.digest().joinToString("") { "%02x".format(it) }

        // Premature EOF verification
        if (contentLength > 0 && bytesWritten < contentLength) {
            tempFile.delete()
            throw IOException("Premature EOF: expected $contentLength bytes but received only $bytesWritten bytes")
        }

        // Checksum verification
        if (!expectedSha256.isNullOrEmpty() && !computedHash.equals(expectedSha256, ignoreCase = true)) {
            tempFile.delete()
            throw IOException("Checksum mismatch: expected $expectedSha256 but got $computedHash")
        }

        // Collision resolution: photo.png -> photo (1).png
        val finalDestination = synchronized(destinationLock) {
            val dest = resolveUniqueDestinationFile(sanitized)
            if (!tempFile.renameTo(dest)) {
                try {
                    Files.move(tempFile.toPath(), dest.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                } catch (e: Exception) {
                    Files.move(tempFile.toPath(), dest.toPath(), StandardCopyOption.REPLACE_EXISTING)
                }
            }
            dest
        }

        loopSuppression.record(computedHash)
        indexAndNotifyFile(finalDestination, dropType)

        return finalDestination
    }

    /**
     * Fallback file receiver when file is pre-staged by AndroidHttpServer.
     */
    fun handleFileReceived(transferId: String, filename: String, type: String, file: File, sha256: String) {
        scope.launch(Dispatchers.IO) {
            indexAndNotifyFile(file, type)
        }
    }

    /**
     * Resolves unique file in incoming directory to avoid overwriting existing files.
     */
    fun resolveUniqueDestinationFile(desiredName: String): File {
        return Companion.resolveUniqueDestinationFile(incomingDir, desiredName)
    }

    /**
     * Submits final file to Android MediaScanner for instantaneous indexation.
     */
    fun indexAndNotifyFile(file: File, type: String) {
        val mimeType = getMimeType(file)
        try {
            MediaScannerConnection.scanFile(
                context,
                arrayOf(file.absolutePath),
                arrayOf(mimeType)
            ) { path, uri ->
                Log.i(TAG, "MediaScanner indexed: $path -> $uri")
                onItemIndexed?.invoke(path, uri?.toString())
            }
        } catch (e: Exception) {
            // MediaScanner failure fallback: file remains safe on disk
            Log.w(TAG, "MediaScannerConnection failed, file remains accessible: ${file.name}", e)
        }

        postFileReceivedNotification(file)
    }

    /**
     * Processes inbound prompt or clipboard text from Mac.
     */
    fun handleTextReceived(payload: TextPayload) {
        if (!payload.origin.isNullOrEmpty()) {
            PeerTargetManager.setMacDeviceId(payload.origin)
        }
        // Store in memory for immediate code-block presentation in MainActivity
        PeerTargetManager.latestReceivedText = payload.text

        scope.launch(Dispatchers.IO) {
            // Also persist as a text/prompt file in incoming storage
            try {
                val prefix = if (payload.type == "prompt") "prompt" else "note"
                val textFile = File(incomingDir, "${prefix}_${System.currentTimeMillis()}.txt")
                textFile.writeText(payload.text)
                indexAndNotifyFile(textFile, "text")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to persist text file: ${e.message}")
            }
        }

        scope.launch(Dispatchers.Main) {
            // 1. Update Android System Clipboard
            try {
                val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = ClipData.newPlainText("Daylight Drop", payload.text)
                clip.description.extras = PersistableBundle().apply {
                    putString(ProtocolConstants.ORIGIN_TAG, payload.origin)
                    putString(ProtocolConstants.TRANSFER_ID_TAG, payload.id)
                }
                clipboardManager.setPrimaryClip(clip)
                Log.i(TAG, "Android clipboard updated with inbound text (${payload.text.length} chars)")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update clipboard", e)
            }

            // 2. Post Sol:OS Heads-Up Banner Notification (<500ms SLA)
            postPromptHeadsUpNotification(payload)
            onPromptReceived?.invoke(payload)
        }
    }

    private fun postPromptHeadsUpNotification(payload: TextPayload) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        // Copy Intent
        val copyIntent = Intent(context, DaylightDropService::class.java).apply {
            action = DaylightDropService.ACTION_COPY_CLIPBOARD
            putExtra("text", payload.text)
        }
        val copyPendingIntent = PendingIntent.getService(
            context,
            payload.id.hashCode(),
            copyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, DaylightDropService.CHANNEL_PROMPTS)
            .setSmallIcon(R.drawable.ic_drop_prompt)
            .setContentTitle("Prompt from Mac")
            .setContentText(payload.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(payload.text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setSound(null)
            .setVibrate(null)
            .setAutoCancel(true)
            .addAction(android.R.drawable.ic_menu_save, "Copy", copyPendingIntent)
            .build()

        nm.notify(payload.id.hashCode(), notification)
        Log.d(TAG, "Posted Sol:OS heads-up banner for prompt id=${payload.id}")
    }

    private fun postFileReceivedNotification(file: File) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        val notification = NotificationCompat.Builder(context, DaylightDropService.CHANNEL_DROPS)
            .setSmallIcon(R.drawable.ic_drop_file)
            .setContentTitle("File Received")
            .setContentText("${file.name} (${formatBytes(file.length())})")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setSound(null)
            .setVibrate(null)
            .setAutoCancel(true)
            .build()

        nm.notify(file.hashCode(), notification)
    }

    fun cleanupStaleTempFiles() {
        scope.launch(Dispatchers.IO) {
            try {
                val now = System.currentTimeMillis()
                val files = incomingDir.listFiles() ?: return@launch
                for (f in files) {
                    if (f.name.startsWith(ProtocolConstants.TEMP_PREFIX) || f.name.endsWith(ProtocolConstants.PART_SUFFIX)) {
                        // Purge temp files older than 1 hour
                        if (now - f.lastModified() > 3_600_000L) {
                            f.delete()
                            Log.d(TAG, "Purged stale staging file: ${f.name}")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error cleaning stale temp files", e)
            }
        }
    }

    fun sanitizeFilename(name: String): String = Companion.sanitizeFilename(name)

    fun getMimeType(file: File): String {
        val extension = file.extension.lowercase(Locale.US)
        if (extension == "heic") return "image/heic"
        if (extension == "heif") return "image/heif"
        return MimeTypeMap.getSingleton()?.getMimeTypeFromExtension(extension) ?: "application/octet-stream"
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return "%.1f KB".format(kb)
        val mb = kb / 1024.0
        return "%.1f MB".format(mb)
    }

    companion object {
        private val destinationLock = Any()

        fun sanitizeFilename(name: String): String {
            return name.replace(Regex("[/\\\\?%*:|\"<>]"), "_").trim().take(255)
        }

        fun resolveUniqueDestinationFile(incomingDir: File, desiredName: String): File {
            synchronized(destinationLock) {
                if (!incomingDir.exists()) {
                    incomingDir.mkdirs()
                }
                val safeName = sanitizeFilename(desiredName)
                val dotIndex = safeName.lastIndexOf('.')
                val baseName = if (dotIndex > 0) safeName.substring(0, dotIndex) else safeName
                val extension = if (dotIndex > 0) safeName.substring(dotIndex) else ""

                var target = File(incomingDir, safeName)
                var index = 1
                while (target.exists()) {
                    target = File(incomingDir, "$baseName ($index)$extension")
                    index++
                }
                return target
            }
        }
    }
}
