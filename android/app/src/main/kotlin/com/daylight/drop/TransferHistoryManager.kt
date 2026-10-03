package com.daylight.drop

import android.content.Context
import android.os.Environment
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.*
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "TransferHistoryManager"
private const val HISTORY_FILENAME = ".history.json"
private const val MAX_HISTORY_ITEMS = 50

data class TransferRecord(
    val id: String = UUID.randomUUID().toString(),
    val filename: String,
    val file: File,
    val size: Long,
    val timestamp: Long,
    val isOutbound: Boolean, // true = Sent to Mac, false = Received from Mac
    val transferType: String, // "screenshot", "file", "prompt", "clipboard", "note"
    val previewText: String? = null
)

object TransferHistoryManager {

    private val sentItems = Collections.synchronizedList(mutableListOf<TransferRecord>())
    private var baseDir: File? = null
    var onHistoryChanged: (() -> Unit)? = null

    fun init(context: Context) {
        baseDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "DaylightDrop")
        if (baseDir?.exists() == false) {
            baseDir?.mkdirs()
        }
        loadHistoryFromDisk()
    }

    fun recordSentItem(file: File, transferType: String = "file", previewText: String? = null) {
        val record = TransferRecord(
            filename = file.name,
            file = file,
            size = if (file.exists()) file.length() else 0L,
            timestamp = System.currentTimeMillis(),
            isOutbound = true,
            transferType = transferType,
            previewText = previewText
        )
        synchronized(sentItems) {
            sentItems.removeAll { it.filename == file.name && it.isOutbound }
            sentItems.add(0, record)
            if (sentItems.size > MAX_HISTORY_ITEMS) {
                sentItems.removeAt(sentItems.size - 1)
            }
        }
        saveHistoryToDisk()
        onHistoryChanged?.invoke()
    }

    fun getSentItems(): List<TransferRecord> {
        val results = mutableListOf<TransferRecord>()
        val seenPaths = mutableSetOf<String>()

        // 1. Items explicitly recorded in memory / history
        synchronized(sentItems) {
            for (item in sentItems) {
                if (item.file.exists() && seenPaths.add(item.file.absolutePath)) {
                    results.add(item)
                }
            }
        }

        // 2. Discover recent screenshots in /sdcard/Pictures/Screenshots (auto-synced to Mac)
        try {
            val picturesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            val screenshotsDir = File(picturesDir, "Screenshots")
            if (screenshotsDir.exists() && screenshotsDir.isDirectory) {
                val screenshotFiles = screenshotsDir.listFiles()?.filter {
                    val name = it.name.lowercase(Locale.US)
                    name.endsWith(".png") || name.endsWith(".jpg") || name.endsWith(".jpeg") || name.endsWith(".webp")
                }?.sortedByDescending { it.lastModified() }?.take(15) ?: emptyList()

                for (sc in screenshotFiles) {
                    if (seenPaths.add(sc.absolutePath)) {
                        results.add(
                            TransferRecord(
                                id = "sc_${sc.lastModified()}",
                                filename = sc.name,
                                file = sc,
                                size = sc.length(),
                                timestamp = sc.lastModified(),
                                isOutbound = true,
                                transferType = "screenshot"
                            )
                        )
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error querying screenshots for sent history", e)
        }

        return results.sortedByDescending { it.timestamp }
    }

    fun getReceivedItems(): List<TransferRecord> {
        val results = mutableListOf<TransferRecord>()
        val dir = baseDir ?: return results
        if (!dir.exists()) return results

        val files = dir.listFiles()?.filter {
            !it.name.startsWith(".") && !it.name.startsWith(".tmp_") && !it.name.endsWith(".part")
        }?.sortedByDescending { it.lastModified() }?.take(25) ?: emptyList()

        for (file in files) {
            val ext = file.extension.lowercase(Locale.US)
            val type = when {
                ext in listOf("png", "jpg", "jpeg", "webp") -> "image"
                ext == "pdf" -> "pdf"
                ext in listOf("md", "txt") && file.name.startsWith("prompt_") -> "prompt"
                ext in listOf("md", "txt") -> "note"
                else -> "file"
            }
            val preview = if (ext in listOf("md", "txt", "json", "xml", "csv")) {
                try {
                    file.bufferedReader().useLines { lines ->
                        lines.take(3).joinToString("\n")
                    }
                } catch (_: Exception) { null }
            } else null

            results.add(
                TransferRecord(
                    id = "in_${file.name}_${file.lastModified()}",
                    filename = file.name,
                    file = file,
                    size = file.length(),
                    timestamp = file.lastModified(),
                    isOutbound = false,
                    transferType = type,
                    previewText = preview
                )
            )
        }
        return results
    }

    private fun saveHistoryToDisk() {
        try {
            val dir = baseDir ?: return
            val file = File(dir, HISTORY_FILENAME)
            val jsonArray = JSONArray()
            synchronized(sentItems) {
                for (item in sentItems.take(MAX_HISTORY_ITEMS)) {
                    val obj = JSONObject().apply {
                        put("id", item.id)
                        put("filename", item.filename)
                        put("path", item.file.absolutePath)
                        put("size", item.size)
                        put("timestamp", item.timestamp)
                        put("isOutbound", item.isOutbound)
                        put("transferType", item.transferType)
                        put("previewText", item.previewText ?: "")
                    }
                    jsonArray.put(obj)
                }
            }
            file.writeText(jsonArray.toString())
        } catch (e: Exception) {
            Log.w(TAG, "Error saving history to disk", e)
        }
    }

    private fun loadHistoryFromDisk() {
        try {
            val dir = baseDir ?: return
            val file = File(dir, HISTORY_FILENAME)
            if (!file.exists()) return

            val content = file.readText()
            val jsonArray = JSONArray(content)
            synchronized(sentItems) {
                sentItems.clear()
                for (i in 0 until jsonArray.length()) {
                    val obj = jsonArray.getJSONObject(i)
                    val path = obj.getString("path")
                    val f = File(path)
                    if (f.exists()) {
                        sentItems.add(
                            TransferRecord(
                                id = obj.optString("id", UUID.randomUUID().toString()),
                                filename = obj.getString("filename"),
                                file = f,
                                size = obj.optLong("size", f.length()),
                                timestamp = obj.optLong("timestamp", f.lastModified()),
                                isOutbound = obj.optBoolean("isOutbound", true),
                                transferType = obj.optString("transferType", "file"),
                                previewText = obj.optString("previewText").takeIf { it.isNotEmpty() }
                            )
                        )
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error loading history from disk", e)
        }
    }
}
