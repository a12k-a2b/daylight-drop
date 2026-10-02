package com.daylight.drop.transport

import android.content.ClipDescription
import android.os.PersistableBundle
import java.security.MessageDigest
import java.util.Collections
import java.util.LinkedHashMap

/**
 * 3-Tier Loop Suppression Engine for Daylight Drop on DC1 (Android / Sol:OS).
 * Prevents infinite clipboard and prompt reflection cycles.
 */
class LoopSuppressionEngine(
    val localDeviceId: String,
    private val capacity: Int = ProtocolConstants.DEFAULT_LRU_CAPACITY,
    private val ttlMs: Long = ProtocolConstants.DEFAULT_TTL_MS
) {
    // Thread-safe LRU cache mapping SHA-256 string to epoch timestamp in ms
    private val cache = Collections.synchronizedMap(
        object : LinkedHashMap<String, Long>(capacity, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean {
                return size > capacity
            }
        }
    )

    // MARK: - Tier 1: Protocol Origin Checking

    fun isOriginSelf(origin: String): Boolean {
        return origin == localDeviceId
    }

    // MARK: - Tier 2: ClipDescription Metadata Tagging

    fun tagClipDescription(
        description: ClipDescription,
        origin: String = localDeviceId,
        transferId: String = java.util.UUID.randomUUID().toString()
    ) {
        val bundle = description.extras ?: PersistableBundle()
        bundle.putString(ProtocolConstants.ORIGIN_TAG, origin)
        bundle.putString(ProtocolConstants.TRANSFER_ID_TAG, transferId)
        description.extras = bundle
    }

    fun getClipDescriptionOrigin(description: ClipDescription): String? {
        val extras = description.extras ?: return null
        return extras.getString(ProtocolConstants.ORIGIN_TAG)
    }

    fun isClipDescriptionFromSelf(description: ClipDescription): Boolean {
        val origin = getClipDescriptionOrigin(description) ?: return false
        return isOriginSelf(origin)
    }

    // MARK: - Tier 3: In-Memory SHA-256 LRU Deduplication

    fun record(hash: String, timestamp: Long = System.currentTimeMillis()) {
        recordHash(hash, timestamp)
    }

    fun recordHash(hash: String, timestamp: Long = System.currentTimeMillis()) {
        pruneExpired(timestamp)
        cache[hash] = timestamp
    }

    fun recordText(text: String, timestamp: Long = System.currentTimeMillis()) {
        val hash = computeSha256(text)
        recordHash(hash, timestamp)
    }

    fun shouldSuppress(hash: String, timestamp: Long = System.currentTimeMillis()): Boolean {
        return shouldSuppressHash(hash, timestamp)
    }

    fun shouldSuppressHash(hash: String, timestamp: Long = System.currentTimeMillis()): Boolean {
        val recordedTime = cache[hash] ?: return false
        if (timestamp - recordedTime > ttlMs) {
            cache.remove(hash)
            return false
        }
        return true
    }

    fun shouldSuppressText(text: String, timestamp: Long = System.currentTimeMillis()): Boolean {
        val hash = computeSha256(text)
        return shouldSuppressHash(hash, timestamp)
    }

    fun shouldSuppressIncoming(origin: String, hash: String, timestamp: Long = System.currentTimeMillis()): Boolean {
        if (isOriginSelf(origin)) {
            return true
        }
        return shouldSuppressHash(hash, timestamp)
    }

    fun currentCacheCount(): Int {
        return cache.size
    }

    fun clear() {
        cache.clear()
    }

    private fun pruneExpired(currentTime: Long) {
        synchronized(cache) {
            val iterator = cache.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (currentTime - entry.value > ttlMs) {
                    iterator.remove()
                }
            }
        }
    }

    companion object {
        fun computeSha256(bytes: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256")
            val hash = digest.digest(bytes)
            val sb = java.lang.StringBuilder(hash.size * 2)
            for (b in hash) {
                sb.append(String.format("%02x", b))
            }
            return sb.toString()
        }

        fun computeSha256(text: String): String {
            return computeSha256(text.toByteArray(Charsets.UTF_8))
        }
    }
}
