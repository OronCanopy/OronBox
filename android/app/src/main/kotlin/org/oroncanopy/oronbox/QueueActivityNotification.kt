package org.oroncanopy.oronbox

import org.zxor.oronbox.MainActivity

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

internal object QueueActivityNotification {
    private const val CHANNEL_ID = "oronbox_queue_activity"
    private const val NOTIFICATION_ID = 2402

    fun update(context: Context, values: Map<*, *>) {
        if (values["active"] != true) {
            clear(context)
            return
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        ensureChannel(manager)
        val title = values["title"]?.toString()?.ifBlank { null }
            ?: context.getString(R.string.widget_queue_title)
        val status = values["status"]?.toString()?.ifBlank { null }
            ?: context.getString(R.string.widget_queue_waiting)
        val progress = ((values["progress"] as? Number)?.toInt() ?: 0).coerceIn(0, 100)
        val total = (values["total"] as? Number)?.toInt() ?: 0
        val active = values["active"] == true
        val pendingIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("$progress% · $title")
            .setContentText(if (total > 0) "$status · $total" else status)
            .setProgress(100, progress, !active)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        manager.notify(NOTIFICATION_ID, builder.build())
    }

    fun clear(context: Context) {
        context.getSystemService(NotificationManager::class.java)
            .cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "OronBox queue progress",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows resource queue progress"
                setShowBadge(false)
            },
        )
    }
}
