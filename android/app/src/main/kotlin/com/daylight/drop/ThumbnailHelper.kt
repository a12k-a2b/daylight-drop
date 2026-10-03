package com.daylight.drop

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Log
import android.util.LruCache
import android.widget.ImageView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

private const val TAG = "ThumbnailHelper"

object ThumbnailHelper {

    private val maxMemory = (Runtime.getRuntime().maxMemory() / 1024).toInt()
    private val cacheSize = maxMemory / 8 // 1/8th of available memory

    private val memoryCache = object : LruCache<String, Bitmap>(cacheSize) {
        override fun sizeOf(key: String, bitmap: Bitmap): Int {
            return bitmap.byteCount / 1024
        }
    }

    fun loadThumbnail(
        context: Context,
        file: File,
        imageView: ImageView,
        targetWidth: Int = 144,
        targetHeight: Int = 144,
        scope: CoroutineScope,
        onSuccess: (() -> Unit)? = null,
        onFallback: (() -> Unit)? = null
    ) {
        val cacheKey = "${file.absolutePath}_${file.lastModified()}_${targetWidth}x${targetHeight}"
        val cached = memoryCache.get(cacheKey)
        if (cached != null) {
            imageView.setImageBitmap(cached)
            onSuccess?.invoke()
            return
        }

        // Tag the ImageView to avoid race conditions with view recycling
        imageView.tag = file.absolutePath

        scope.launch(Dispatchers.IO) {
            val bitmap = try {
                val ext = file.extension.lowercase(Locale.US)
                when {
                    ext in listOf("png", "jpg", "jpeg", "webp", "heic", "heif") -> {
                        decodeSampledBitmapFromFile(file, targetWidth, targetHeight)
                    }
                    ext == "pdf" -> {
                        renderPdfFirstPage(file, targetWidth, targetHeight)
                    }
                    else -> null
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error generating thumbnail for ${file.name}", e)
                null
            }

            withContext(Dispatchers.Main) {
                if (imageView.tag == file.absolutePath) {
                    if (bitmap != null) {
                        memoryCache.put(cacheKey, bitmap)
                        imageView.setImageBitmap(bitmap)
                        onSuccess?.invoke()
                    } else {
                        onFallback?.invoke()
                    }
                }
            }
        }
    }

    private fun decodeSampledBitmapFromFile(file: File, reqWidth: Int, reqHeight: Int): Bitmap? {
        val options = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        BitmapFactory.decodeFile(file.absolutePath, options)

        var inSampleSize = 1
        if (options.outHeight > reqHeight || options.outWidth > reqWidth) {
            val halfHeight = options.outHeight / 2
            val halfWidth = options.outWidth / 2
            while ((halfHeight / inSampleSize) >= reqHeight && (halfWidth / inSampleSize) >= reqWidth) {
                inSampleSize *= 2
            }
        }

        options.inSampleSize = inSampleSize
        options.inJustDecodeBounds = false
        options.inPreferredConfig = Bitmap.Config.RGB_565 // Grayscale / low-memory friendly for DC1
        return BitmapFactory.decodeFile(file.absolutePath, options)
    }

    private fun renderPdfFirstPage(file: File, reqWidth: Int, reqHeight: Int): Bitmap? {
        var pfd: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        var page: PdfRenderer.Page? = null
        return try {
            pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(pfd)
            if (renderer.pageCount <= 0) return null

            page = renderer.openPage(0)
            val aspect = page.width.toFloat() / page.height.toFloat()
            val w = if (aspect >= 1.0f) reqWidth else (reqHeight * aspect).toInt()
            val h = if (aspect >= 1.0f) (reqWidth / aspect).toInt() else reqHeight

            val bitmap = Bitmap.createBitmap(maxOf(w, 1), maxOf(h, 1), Bitmap.Config.RGB_565)
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            bitmap
        } catch (e: Exception) {
            Log.w(TAG, "PdfRenderer failed for ${file.name}: ${e.message}")
            null
        } finally {
            try { page?.close() } catch (_: Exception) {}
            try { renderer?.close() } catch (_: Exception) {}
            try { pfd?.close() } catch (_: Exception) {}
        }
    }
}
