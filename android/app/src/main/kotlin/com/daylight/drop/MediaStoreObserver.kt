package com.daylight.drop

import android.content.ContentUris
import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import com.daylight.drop.transport.AndroidTransportManager
import com.daylight.drop.transport.LoopSuppressionEngine
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "DaylightDropMediaObs"
private const val PREFS_NAME = "daylight_drop_observer_prefs"
private const val KEY_LAST_ID = "last_processed_screenshot_id"

/**
 * ContentObserver monitoring MediaStore.Images.Media.EXTERNAL_CONTENT_URI on DC1.
 * Filters for completed screenshots (IS_PENDING == 0 in Pictures/Screenshots)
 * and streams them to Mac via AndroidTransportManager within <1500ms SLA.
 */
class MediaStoreObserver(
    private val context: Context,
    private val transportManager: AndroidTransportManager,
    private val scope: CoroutineScope,
    private val onScreenshotDispatched: ((File, String) -> Unit)? = null
) : ContentObserver(Handler(Looper.getMainLooper())) {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private var lastProcessedId: Long = prefs.getLong(KEY_LAST_ID, 0L)

    private val isRegistered = AtomicBoolean(false)
    private val isChecking = AtomicBoolean(false)
    private val needsRecheck = AtomicBoolean(false)
    private val inFlightIds = ConcurrentHashMap.newKeySet<Long>()

    fun start() {
        if (!isRegistered.compareAndSet(false, true)) return

        // If running for the first time, initialize lastProcessedId to highest existing ID
        // so that past gallery history is not sent in a massive burst.
        if (lastProcessedId == 0L) {
            lastProcessedId = queryHighestExistingId()
            saveLastProcessedId(lastProcessedId)
        }

        try {
            context.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                this
            )
            Log.i(TAG, "MediaStoreObserver registered with watermark ID=$lastProcessedId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register MediaStoreObserver", e)
        }
    }

    fun stop() {
        if (!isRegistered.compareAndSet(true, false)) return
        try {
            context.contentResolver.unregisterContentObserver(this)
            Log.i(TAG, "MediaStoreObserver unregistered")
        } catch (e: Exception) {
            Log.w(TAG, "Error unregistering MediaStoreObserver", e)
        }
    }

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)
        scope.launch(Dispatchers.IO) {
            checkForNewScreenshot()
        }
    }

    fun checkForNewScreenshot() {
        if (!isChecking.compareAndSet(false, true)) {
            needsRecheck.set(true)
            return
        }

        try {
            do {
                needsRecheck.set(false)
                performScreenshotQuery()
            } while (needsRecheck.get())
        } finally {
            isChecking.set(false)
            if (needsRecheck.get() && isChecking.compareAndSet(false, true)) {
                try {
                    do {
                        needsRecheck.set(false)
                        performScreenshotQuery()
                    } while (needsRecheck.get())
                } finally {
                    isChecking.set(false)
                }
            }
        }
    }

    private fun performScreenshotQuery() {
        try {
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.DATA,
                MediaStore.Images.Media.IS_PENDING
            )

            // Strict filter: IS_PENDING == 0, SIZE > 0, located in Pictures/Screenshots
            val selection = "${MediaStore.MediaColumns.IS_PENDING} = 0 AND " +
                    "${MediaStore.MediaColumns.SIZE} > 0 AND " +
                    "(${MediaStore.MediaColumns.RELATIVE_PATH} LIKE 'Pictures/Screenshots%' OR " +
                    "${MediaStore.MediaColumns.DATA} LIKE '%/Pictures/Screenshots/%') AND " +
                    "${MediaStore.MediaColumns._ID} > ?"

            val selectionArgs = arrayOf(lastProcessedId.toString())
            val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} ASC, ${MediaStore.MediaColumns._ID} ASC"

            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                sortOrder
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)

                var processedCount = 0
                while (cursor.moveToNext() && processedCount < 10) {
                    processedCount++
                    val id = cursor.getLong(idCol)
                    val filename = cursor.getString(nameCol)
                    val size = cursor.getLong(sizeCol)
                    val path = cursor.getString(dataCol)

                    if (size <= 0L) {
                        Log.d(TAG, "Skipping 0-byte screenshot: $filename")
                        updateWatermark(id)
                        continue
                    }

                    if (!inFlightIds.add(id)) {
                        continue
                    }

                    processAndDispatchScreenshot(id, filename, size, path)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying MediaStore for screenshots", e)
        }
    }

    private fun processAndDispatchScreenshot(id: Long, filename: String, size: Long, path: String) {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        var cachedFile: File? = null
        try {
            // First try reading via ContentResolver (Scoped Storage compliant)
            val inputStream = try {
                context.contentResolver.openInputStream(uri)
            } catch (e: Exception) {
                Log.w(TAG, "ContentResolver could not open URI $uri: ${e.message}")
                null
            }

            val directFile = File(path)
            if (inputStream == null && (!directFile.exists() || !directFile.canRead())) {
                Log.w(TAG, "Screenshot not accessible via URI or disk: $filename")
                updateWatermark(id)
                inFlightIds.remove(id)
                return
            }

            cachedFile = File(context.cacheDir, "obs_screenshot_${id}_$filename")
            if (inputStream != null) {
                inputStream.use { input ->
                    FileOutputStream(cachedFile).use { output ->
                        input.copyTo(output)
                    }
                }
            } else {
                directFile.copyTo(cachedFile, overwrite = true)
            }

            if (cachedFile.length() <= 0L) {
                Log.w(TAG, "Screenshot file was 0 bytes on read: $filename")
                updateWatermark(id)
                inFlightIds.remove(id)
                return
            }

            val bytes = cachedFile.readBytes()
            val sha256 = LoopSuppressionEngine.computeSha256(bytes)
            if (transportManager.loopSuppression.shouldSuppress(sha256)) {
                Log.d(TAG, "Suppressing screenshot already in LRU cache: $filename")
                updateWatermark(id)
                inFlightIds.remove(id)
                return
            }

            Log.i(TAG, "Streaming screenshot to Mac: $filename ($size bytes, sha256=$sha256)")
            transportManager.loopSuppression.record(sha256)

            // Stream to Mac using drop_type="screenshot" per contract with TransferWakeLock
            DaylightDropService.acquireWakeLock(60_000L)
            try {
                val response = transportManager.sendFile(cachedFile, type = "screenshot")
                Log.i(TAG, "Screenshot successfully beamed to Mac: ${response.transfer_id}")
                updateWatermark(id)
                onScreenshotDispatched?.invoke(cachedFile, sha256)
            } finally {
                DaylightDropService.releaseWakeLock()
            }
        } catch (e: FileNotFoundException) {
            Log.w(TAG, "Screenshot deleted before dispatch: $filename", e)
            updateWatermark(id)
        } catch (e: IOException) {
            // Transient network I/O error: do not advance watermark so it can retry
            Log.e(TAG, "Transient I/O error streaming screenshot to Mac: $filename (will retry)", e)
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected error streaming screenshot: $filename", e)
        } finally {
            cachedFile?.delete()
            inFlightIds.remove(id)
        }
    }

    private fun updateWatermark(id: Long) {
        if (id > lastProcessedId) {
            lastProcessedId = id
            saveLastProcessedId(id)
        }
    }

    private fun queryHighestExistingId(): Long {
        return try {
            val projection = arrayOf(MediaStore.Images.Media._ID)
            val sortOrder = "${MediaStore.Images.Media._ID} DESC"
            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                null,
                null,
                sortOrder
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getLong(0)
                } else 0L
            } ?: 0L
        } catch (e: Exception) {
            Log.w(TAG, "Could not determine highest MediaStore ID", e)
            0L
        }
    }

    private fun saveLastProcessedId(id: Long) {
        prefs.edit().putLong(KEY_LAST_ID, id).apply()
    }
}
