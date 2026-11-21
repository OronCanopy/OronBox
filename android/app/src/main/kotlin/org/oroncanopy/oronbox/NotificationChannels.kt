package org.oroncanopy.oronbox

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class NotificationChannels(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val method = MethodChannel(messenger, PlatformChannelNames.NOTIFICATIONS)
    private val events = EventChannel(messenger, "${PlatformChannelNames.NOTIFICATIONS}/phone")
    private var openLocation: String? = takeLocation(activity.intent)
    private val manager = activity.getSystemService(NotificationManager::class.java)

    init {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPhoneAccess" -> result.success(hasAccess())
                "openPhoneAccess" -> {
                    activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                }
                "listApps" -> {
                    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = activity.packageManager.queryIntentActivities(intent, 0)
                        .filter { it.activityInfo.packageName != activity.packageName }
                        .distinctBy { it.activityInfo.packageName }
                        .map { mapOf("package" to it.activityInfo.packageName, "name" to it.loadLabel(activity.packageManager).toString()) }
                    result.success(apps)
                }
                "hasSendPermission" -> result.success(NotificationManagerCompat.from(activity).areNotificationsEnabled())
                "openSendSettings" -> {
                    openSendSettings()
                    result.success(null)
                }
                "getInitialLocation" -> {
                    result.success(openLocation)
                    openLocation = null
                }
                "show" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(args != null && show(args))
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                PhoneNotificationListener.onNotification = { sink.success(it) }
            }
            override fun onCancel(arguments: Any?) {
                PhoneNotificationListener.onNotification = null
            }
        })
    }

    private fun openSendSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            try {
                activity.startActivity(intent)
                return
            } catch (_: ActivityNotFoundException) {
            }
        }
        activity.startActivity(Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", activity.packageName, null),
        ))
    }

    private fun hasAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            return manager.isNotificationListenerAccessGranted(ComponentName(activity, PhoneNotificationListener::class.java))
        }
        return NotificationManagerCompat.getEnabledListenerPackages(activity).contains(activity.packageName)
    }

    private fun show(args: Map<*, *>): Boolean {
        if (!NotificationManagerCompat.from(activity).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED) return false
        val id = args["id"] as? String ?: return false
        val category = args["category"] as? String ?: return false
        val location = args["location"] as? String ?: return false
        val title = args["title"] as? String ?: return false
        val body = args["body"] as? String ?: return false
        val channel = "oronbox_$category"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(channel, title, NotificationManager.IMPORTANCE_DEFAULT))
            if (manager.getNotificationChannel(channel)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        val intent = Intent(activity, activity.javaClass)
            .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(LOCATION, location)
        val tap = PendingIntent.getActivity(activity, id.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val icon = activity.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info
        manager.notify(id, 0, NotificationCompat.Builder(activity, channel)
            .setSmallIcon(icon).setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(tap).setAutoCancel(true).build())
        return true
    }

    fun onNewIntent(intent: Intent) {
        takeLocation(intent)?.let { method.invokeMethod("notificationOpened", it) }
    }

    fun dispose() {
        PhoneNotificationListener.onNotification = null
        events.setStreamHandler(null)
        method.setMethodCallHandler(null)
    }

    private fun takeLocation(intent: Intent?): String? = intent?.getStringExtra(LOCATION)?.also {
        intent.removeExtra(LOCATION)
    }

    companion object {
        private const val LOCATION = "org.oroncanopy.oronbox.notification_location"
    }
}
