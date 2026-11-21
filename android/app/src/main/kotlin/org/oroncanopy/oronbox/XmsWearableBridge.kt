package org.oroncanopy.oronbox

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

object XmsWearableBridge {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val inboundListeners = CopyOnWriteArrayList<(String, String, ByteArray) -> Unit>()
    private val dataListeners = CopyOnWriteArrayList<(String, Int, Any?) -> Unit>()
    @Volatile private var channel: MethodChannel? = null

    fun attach(value: MethodChannel) {
        channel = value
        value.setMethodCallHandler { call, result ->
            when (call.method) {
                "messageReceived" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    val nodeId = call.argument<String>("nodeId") ?: ""
                    val payload = call.argument<ByteArray>("payload") ?: byteArrayOf()
                    inboundListeners.forEach { it(packageName, nodeId, payload) }
                    result.success(null)
                }
                "dataChanged" -> {
                    val nodeId = call.argument<String>("nodeId") ?: ""
                    val type = call.argument<Int>("type") ?: 0
                    val value = call.argument<Any>("value")
                    dataListeners.forEach { it(nodeId, type, value) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach(value: MethodChannel?) {
        if (channel === value) channel = null
    }

    fun isReady(): Boolean = channel != null

    fun invoke(method: String, arguments: Any?, callback: MethodChannel.Result) {
        val current = channel
        if (current == null) {
            callback.error("disconnected", "Flutter runtime is not ready", null)
            return
        }
        mainHandler.post { current.invokeMethod(method, arguments, callback) }
    }

    fun addInboundListener(listener: (String, String, ByteArray) -> Unit) = inboundListeners.add(listener)
    fun removeInboundListener(listener: (String, String, ByteArray) -> Unit) = inboundListeners.remove(listener)
    fun addDataListener(listener: (String, Int, Any?) -> Unit) = dataListeners.add(listener)
    fun removeDataListener(listener: (String, Int, Any?) -> Unit) = dataListeners.remove(listener)
}
