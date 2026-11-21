package org.zxor.oronbox

import org.oroncanopy.oronbox.XmsWearableBridge

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.RemoteException
import android.util.Log
import com.xiaomi.xms.wearable.IServiceConnectedListener
import com.xiaomi.xms.wearable.IWearableInterface
import com.xiaomi.xms.wearable.Status
import com.xiaomi.xms.wearable.auth.IPermissionCallback
import com.xiaomi.xms.wearable.auth.IPermissionCheckCallback
import com.xiaomi.xms.wearable.auth.IPermissionsCheckCallback
import com.xiaomi.xms.wearable.auth.Permission
import com.xiaomi.xms.wearable.message.IMessageCallback
import com.xiaomi.xms.wearable.message.IMessageListener
import com.xiaomi.xms.wearable.node.DataItem
import com.xiaomi.xms.wearable.node.IDataCallback
import com.xiaomi.xms.wearable.node.IDataListener
import com.xiaomi.xms.wearable.node.INodeCallback
import com.xiaomi.xms.wearable.node.IWearAppInstalledCallback
import com.xiaomi.xms.wearable.node.IWearAppLaunchedCallback
import com.xiaomi.xms.wearable.node.Node
import com.xiaomi.xms.wearable.notify.INotifyCallback
import com.xiaomi.xms.wearable.notify.NotificationData
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap

class OronBoxWearableService : Service() {
    companion object {
        private const val TAG = "OronBoxXmsService"
    }

    private data class MessageRegistration(
        val packageName: String,
        val listener: IMessageListener,
    )

    private val messageListeners = ConcurrentHashMap<String, MessageRegistration>()
    private val dataListeners = ConcurrentHashMap<String, IDataListener>()
    private val connectedListeners = ConcurrentHashMap<IBinder, IServiceConnectedListener>()
    private val inbound: (String, String, ByteArray) -> Unit = inbound@{ packageName, nodeId, payload ->
        val registration = messageListeners[packageName]
            ?: if (messageListeners.size == 1) messageListeners.values.firstOrNull() else null
        if (registration == null) {
            Log.w(
                TAG,
                "dropping interconnect reply: no listener for package=$packageName " +
                    "registrations=${messageListeners.keys}",
            )
            return@inbound
        }
        Log.d(
            TAG,
            "delivering interconnect reply package=${registration.packageName} " +
                "sourcePackage=$packageName bytes=${payload.size}",
        )
        try {
            registration.listener.onMessageReceived(
                nodeId.ifBlank { currentNodeId() },
                payload,
            )
        } catch (_: RemoteException) {
            messageListeners.remove(registration.packageName, registration)
        }
    }
    private val dataChanged: (String, Int, Any?) -> Unit = dataChanged@{ nodeId, type, value ->
        val item = dataItem(type) ?: return@dataChanged
        val values = dataBundle(type, value)
        dataListeners.entries.filter { it.key.endsWith(":$type") }.forEach { entry ->
            try {
                entry.value.onDataChanged(nodeId.ifBlank { currentNodeId() }, item, values)
            } catch (_: RemoteException) {
                dataListeners.remove(entry.key, entry.value)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        XmsWearableBridge.addInboundListener(inbound)
        XmsWearableBridge.addDataListener(dataChanged)
    }

    override fun onDestroy() {
        XmsWearableBridge.removeInboundListener(inbound)
        XmsWearableBridge.removeDataListener(dataChanged)
        messageListeners.clear()
        dataListeners.clear()
        connectedListeners.clear()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    private val binder = object : IWearableInterface.Stub() {
        override fun getServiceApiLevel(): Int = 1

        override fun checkPermission(
            nodeId: String?, permission: Permission?, callback: IPermissionCheckCallback?,
        ) = verifyCaller { allowed ->
            if (allowed) callback?.onPermissionGranted(true)
            else callback?.onFailure(Status.RESULT_SIGNATURE_VERIFY_FAILED)
        }

        override fun checkPermissions(
            nodeId: String?, permissions: Array<out Permission>?,
            callback: IPermissionsCheckCallback?,
        ) = verifyCaller { allowed ->
            if (allowed) callback?.onPermissionGranted(BooleanArray(permissions?.size ?: 0) { true })
            else callback?.onFailure(Status.RESULT_SIGNATURE_VERIFY_FAILED)
        }

        override fun requestPermission(
            nodeId: String?, permissions: Array<out Permission>?, callback: IPermissionCallback?,
        ) = verifyCaller { allowed ->
            if (allowed) callback?.onPermissionGranted(permissions ?: emptyArray())
            else callback?.onFailure(Status.RESULT_SIGNATURE_VERIFY_FAILED)
        }

        override fun getConnectedNodes(callback: INodeCallback?) {
            authorize(
                onDenied = { callback?.onFailure(it) },
            ) {
                invoke("getConnectedNodes", null,
                    success = { value ->
                        val nodes = (value as? List<*>)?.mapNotNull { item ->
                            val map = item as? Map<*, *> ?: return@mapNotNull null
                            Node(
                                map["id"]?.toString() ?: return@mapNotNull null,
                                map["name"]?.toString() ?: "",
                            )
                        } ?: emptyList()
                        callback?.onNodesConnected(nodes)
                    },
                    failure = { callback?.onFailure(it) },
                )
            }
        }

        override fun isWearAppInstalled(nodeId: String?, callback: IWearAppInstalledCallback?) {
            authorize(
                onDenied = { callback?.onFailure(it) },
            ) { caller ->
                invoke("isWearAppInstalled", mapOf("packageName" to caller),
                    success = { callback?.onWearAppInstalled(it == true) },
                    failure = { callback?.onFailure(it) },
                )
            }
        }

        override fun launchWearApp(nodeId: String?, uri: String?, callback: IWearAppLaunchedCallback?) {
            authorize(
                onDenied = { callback?.onWearAppLaunched(it) },
            ) { caller ->
                invoke("launchWearApp", mapOf("packageName" to caller, "uri" to (uri ?: "")),
                    success = { callback?.onWearAppLaunched(Status.RESULT_SUCCESS) },
                    failure = { callback?.onWearAppLaunched(it) },
                )
            }
        }

        override fun query(nodeId: String?, dataItem: DataItem?, callback: IDataCallback?) {
            authorize(
                onDenied = { callback?.onFailure(it) },
            ) {
                if (dataItem?.type == 3 || dataItem?.type == 4) {
                    callback?.onFailure(Status.RESULT_INTERRUPTED)
                    return@authorize
                }
                invoke("query", mapOf("type" to (dataItem?.type ?: 0)),
                    success = { value ->
                        val values = Bundle()
                        val map = value as? Map<*, *> ?: emptyMap<Any, Any>()
                        when (dataItem?.type) {
                            1 -> values.putInt(DataItem.KEY_CONNECTION_STATUS, (map["value"] as? Number)?.toInt() ?: 0)
                            2 -> values.putBoolean(DataItem.KEY_CHARGING_STATUS, map["value"] == true)
                            3 -> values.putBoolean(DataItem.KEY_SLEEP_STATUS, map["value"] == true)
                            4 -> values.putBoolean(DataItem.KEY_WEARING_STATUS, map["value"] == true)
                            5 -> values.putInt(DataItem.KEY_BATTERY_STATUS, (map["value"] as? Number)?.toInt() ?: 0)
                        }
                        callback?.onResult(dataItem, values)
                    },
                    failure = { callback?.onFailure(it) },
                )
            }
        }

        override fun subscribe(nodeId: String?, dataItem: DataItem?, listener: IDataListener?) {
            if (dataItem == null || listener == null) return
            requireSupportedDataItem(dataItem)
            authorize { caller ->
                dataListeners[subscriptionKey(caller, dataItem.type)] = listener
            }
        }

        override fun unsubscribe(nodeId: String?, dataItem: DataItem?) {
            if (dataItem == null) return
            requireSupportedDataItem(dataItem)
            authorize { caller ->
                dataListeners.remove(subscriptionKey(caller, dataItem.type))
            }
        }

        override fun sendMessage(nodeId: String?, message: ByteArray?, callback: IMessageCallback?) {
            authorize(
                onDenied = { callback?.onMessageSent(it) },
            ) { caller ->
                Log.d(TAG, "sendMessage caller=$caller node=$nodeId bytes=${message?.size ?: 0}")
                invoke("sendMessage", mapOf("packageName" to caller, "payload" to (message ?: byteArrayOf())),
                    success = { callback?.onMessageSent(Status.RESULT_SUCCESS) },
                    failure = { callback?.onMessageSent(it) },
                )
            }
        }

        override fun addMessageListener(nodeId: String?, listener: IMessageListener?, callback: IMessageCallback?) {
            if (listener == null) return callback?.onMessageSent(Status.RESULT_INTERRUPTED) ?: Unit
            authorize(
                onDenied = { callback?.onMessageSent(it) },
            ) { caller ->
                val registration = MessageRegistration(caller, listener)
                messageListeners[caller] = registration
                try {
                    listener.asBinder().linkToDeath({ messageListeners.remove(caller, registration) }, 0)
                    Log.d(TAG, "message listener registered package=$caller")
                    callback?.onMessageSent(Status.RESULT_SUCCESS)
                } catch (_: RemoteException) {
                    messageListeners.remove(caller, registration)
                    callback?.onMessageSent(Status.RESULT_DISCONNECTED)
                }
            }
        }

        override fun removeMessageListener(nodeId: String?, callback: IMessageCallback?) {
            authorize(
                onDenied = { callback?.onMessageSent(it) },
            ) { caller ->
                messageListeners.remove(caller)
                Log.d(TAG, "message listener removed package=$caller")
                callback?.onMessageSent(Status.RESULT_SUCCESS)
            }
        }

        override fun registerServiceConnectedListener(callback: IServiceConnectedListener?) {
            if (callback == null) return
            authorize {
                connectedListeners[callback.asBinder()] = callback
                callback.asBinder().linkToDeath({ connectedListeners.remove(callback.asBinder()) }, 0)
            }
        }

        override fun sendNotify(nodeId: String?, notification: NotificationData?, callback: INotifyCallback?) {
            authorize(
                onDenied = { callback?.onResult(it) },
            ) { caller ->
                invoke("sendNotify", mapOf(
                    "packageName" to caller,
                    "title" to (notification?.title ?: ""),
                    "message" to (notification?.message ?: ""),
                ), success = { callback?.onResult(Status.RESULT_SUCCESS) }, failure = { callback?.onResult(it) })
            }
        }
    }

    private fun verifyCaller(done: (Boolean) -> Unit) {
        authorize(
            onDenied = { done(false) },
        ) { done(true) }
    }

    private fun authorize(
        onDenied: (Status) -> Unit = {},
        done: (String) -> Unit,
    ) {
        val uid = Binder.getCallingUid()
        val packageName = callerPackage(uid)
        if (packageName == null) {
            onDenied(Status.RESULT_SIGNATURE_VERIFY_FAILED)
            return
        }
        val fingerprint = packageFingerprint(packageName)
        Log.d(TAG, "authorizing caller=$packageName uid=$uid fingerprintBytes=${fingerprint.size}")
        invoke("verifyCaller", mapOf("packageName" to packageName, "fingerprint" to fingerprint),
            success = {
                Log.d(TAG, "caller verification package=$packageName allowed=${it == true}")
                if (it == true) done(packageName)
                else onDenied(Status.RESULT_SIGNATURE_VERIFY_FAILED)
            },
            failure = {
                Log.w(TAG, "caller verification failed package=$packageName status=${it.code}")
                onDenied(it)
            },
        )
    }

    private fun callerPackage(uid: Int = Binder.getCallingUid()): String? =
        packageManager.getNameForUid(uid)?.takeIf { it.isNotBlank() }

    @Suppress("DEPRECATION")
    private fun packageFingerprint(packageName: String): ByteArray {
        val info = try {
            packageManager.getPackageInfo(
                packageName,
                android.content.pm.PackageManager.GET_SIGNATURES,
            ).signatures?.takeIf { it.size == 1 }?.singleOrNull()?.toByteArray()
        } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
            null
        } ?: return byteArrayOf()
        // Vela's AppItem.BasicInfo.fingerprint is the raw SHA-1 digest of the
        // DER-encoded signing certificate (20 bytes), not the Android
        // package-signing SHA-256 digest. Keep this byte-for-byte compatible
        // with the fingerprint sent by the watch.
        return java.security.MessageDigest.getInstance("SHA-1").digest(info)
    }

    private fun invoke(method: String, arguments: Any?, success: (Any?) -> Unit, failure: (Status) -> Unit) {
        Log.d(TAG, "bridge invoke method=$method")
        XmsWearableBridge.invoke(method, arguments, object : MethodChannel.Result {
            override fun success(result: Any?) {
                Log.d(TAG, "bridge success method=$method result=${result?.javaClass?.simpleName ?: "null"}")
                success(result)
            }
            override fun error(code: String, message: String?, details: Any?) {
                Log.w(TAG, "bridge error method=$method code=$code message=$message")
                failure(
                    when (code) {
                    "signature" -> Status.RESULT_SIGNATURE_VERIFY_FAILED
                    "permission" -> Status.RESULT_PERMISSION_DENIED
                    "not_installed" -> Status.RESULT_APP_NOT_INSTALLED
                    else -> Status.RESULT_DISCONNECTED
                    },
                )
            }
            override fun notImplemented() {
                Log.w(TAG, "bridge not implemented method=$method")
                failure(Status.RESULT_INTERRUPTED)
            }
        })
    }

    private fun subscriptionKey(packageName: String?, type: Int) = "${packageName.orEmpty()}:$type"
    private fun currentNodeId(): String = "oronbox"

    private fun requireSupportedDataItem(dataItem: DataItem) {
        if (dataItem.type == 3 || dataItem.type == 4) {
            throw UnsupportedOperationException(
                "Sleep and wearing status are not supported by the OronBox backend",
            )
        }
    }

    private fun dataItem(type: Int): DataItem? = when (type) {
        1 -> DataItem.ITEM_CONNECTION
        2 -> DataItem.ITEM_CHARGING
        5 -> DataItem.ITEM_BATTERY
        else -> null
    }

    private fun dataBundle(type: Int, value: Any?): Bundle = Bundle().apply {
        when (type) {
            1 -> putInt(DataItem.KEY_CONNECTION_STATUS, (value as? Number)?.toInt() ?: 0)
            2 -> putInt(DataItem.KEY_CHARGING_STATUS, (value as? Number)?.toInt() ?: 0)
            5 -> putInt(DataItem.KEY_BATTERY_STATUS, (value as? Number)?.toInt() ?: 0)
        }
    }
}
