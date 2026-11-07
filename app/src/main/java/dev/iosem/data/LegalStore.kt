package dev.iosem.data

import android.content.Context

/**
 * One-time acknowledgement that the user owns the hardware and firmware they
 * import and will not redistribute Apple software.
 */
class LegalStore(context: Context) {
    private val prefs = context.getSharedPreferences("legal", Context.MODE_PRIVATE)

    fun isAccepted(): Boolean = prefs.getBoolean(KEY, false)

    fun accept() {
        prefs.edit().putBoolean(KEY, true).apply()
    }

    private companion object {
        const val KEY = "accepted_v1"
    }
}
