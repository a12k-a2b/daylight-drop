package com.daylight.drop

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * DirectShareManager: Publishes and updates dynamic sharing shortcuts
 * with a Person target ("Mac Menu Bar Tray") to rank Daylight Drop at the top
 * of the Android 13 Chooser direct share row.
 *
 * Requirements for Android 13 Direct Share:
 * 1. Category must match `res/xml/shortcuts.xml` (`com.daylight.drop.category.DIRECT_SHARE_TARGET`).
 * 2. Person object MUST be attached via `setPerson(person)`. Android 11+ direct share ranking
 *    is conversation/person-based; shortcuts without Person will NOT surface in the direct share row.
 * 3. `setLongLived(true)` ensures the system retains the shortcut even if unpinned.
 * 4. `setRank(1)` gives it top priority among dynamic shortcuts.
 * 5. Uses `ShortcutManagerCompat.pushDynamicShortcut()`, which automatically handles limits,
 *    updates, and usage reporting.
 */
object DirectShareManager {

    private const val TAG = "DirectShareManager"
    const val DIRECT_SHARE_CATEGORY = "com.daylight.drop.category.DIRECT_SHARE_TARGET"
    const val SHORTCUT_ID_MAC = "shortcut_mac_menu_bar_tray"
    const val DEFAULT_TARGET_NAME = "Mac Menu Bar Tray"

    /**
     * Publishes or updates the dynamic shortcut for the connected Mac.
     * Call on app startup, service start, or whenever peer discovery detects a new Mac name.
     */
    fun publishDirectShareTarget(
        context: Context,
        macDeviceName: String = DEFAULT_TARGET_NAME
    ) {
        try {
            val person = Person.Builder()
                .setName(macDeviceName)
                .setKey("person_mac_tray")
                .setIcon(IconCompat.createWithResource(context, R.drawable.ic_mac_tray))
                .setImportant(true)
                .build()

            val shareIntent = Intent(context, ShareActivity::class.java).apply {
                action = Intent.ACTION_SEND
                putExtra(ShareActivity.EXTRA_TARGET_DEVICE, "mac")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }

            val shortcut = ShortcutInfoCompat.Builder(context, SHORTCUT_ID_MAC)
                .setShortLabel(context.getString(R.string.direct_share_short_label))
                .setLongLabel(context.getString(R.string.direct_share_long_label, macDeviceName))
                .setIcon(IconCompat.createWithResource(context, R.drawable.ic_mac_tray))
                .setPerson(person)
                .setLongLived(true)
                .setCategories(setOf(DIRECT_SHARE_CATEGORY))
                .setIntent(shareIntent)
                .setRank(1)
                .build()

            // pushDynamicShortcut manages limits and signals shortcut usage to the system
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
            Log.i(TAG, "Successfully published direct share shortcut for '$macDeviceName'")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to publish direct share shortcut", e)
        }
    }

    /**
     * Removes the dynamic shortcut (e.g. if explicitly unpaired or reset).
     */
    fun removeDirectShareTarget(context: Context) {
        try {
            ShortcutManagerCompat.removeDynamicShortcuts(context, listOf(SHORTCUT_ID_MAC))
            Log.i(TAG, "Removed direct share shortcut")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to remove direct share shortcut", e)
        }
    }
}
