package org.oroncanopy.oronbox

import android.app.Notification
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class PhoneNotificationListener : NotificationListenerService() {
    companion object {
        private val main = Handler(Looper.getMainLooper())
        var onNotification: ((Map<String, Any>) -> Unit)? = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) = emit(sbn, false)

    override fun onNotificationRemoved(sbn: StatusBarNotification) = emit(sbn, true)

    private fun emit(sbn: StatusBarNotification, removed: Boolean) {
        if (sbn.packageName == packageName) return
        val extras = sbn.notification.extras
        val event = mutableMapOf<String, Any>(
            "key" to sbn.key,
            "package" to sbn.packageName,
            "removed" to removed,
        )
        if (!removed) {
            if (sbn.isOngoing || sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
            if (title.isBlank() && text.isBlank()) return
            val label = runCatching {
                val info = packageManager.getApplicationInfo(sbn.packageName, 0)
                packageManager.getApplicationLabel(info).toString()
            }.getOrDefault(sbn.packageName)
            event.putAll(mapOf(
                "appName" to label,
                "title" to title.take(256),
                "body" to text.take(2048),
                "timestamp" to sbn.postTime,
            ))
        }
        main.post { onNotification?.invoke(event) }
    }
}
