package org.oroncanopy.oronbox

import android.content.Context

internal object StatusWidgetDataStore {
    private const val PREFS = "oronbox_status_surfaces"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun saveDevice(context: Context, values: Map<*, *>) {
        prefs(context).edit()
            .putBoolean("device.has", values.boolean("hasDevice"))
            .putString("device.name", values.string("deviceName"))
            .putBoolean("device.connected", values.boolean("connected"))
            .putBoolean("device.connecting", values.boolean("connecting"))
            .putInt("device.battery", values.int("battery"))
            .putBoolean("device.charging", values.boolean("charging"))
            .putLong("device.storageUsed", values.long("storageUsed"))
            .putLong("device.storageTotal", values.long("storageTotal"))
            .putInt("device.appCount", values.int("appCount"))
            .putInt("device.watchfaceCount", values.int("watchfaceCount"))
            .putLong("device.updatedAt", values.long("updatedAt"))
            .apply()
    }

    fun saveHealth(context: Context, values: Map<*, *>) {
        prefs(context).edit()
            .putInt("health.steps", values.int("steps"))
            .putInt("health.activeCalories", values.int("activeCalories"))
            .putInt("health.standingHours", values.int("standingHours"))
            .putInt("health.heartRate", values.int("heartRate"))
            .putLong("health.heartRateAt", values.long("heartRateAt"))
            .putInt("health.bloodOxygen", values.int("bloodOxygen"))
            .putLong("health.bloodOxygenAt", values.long("bloodOxygenAt"))
            .putInt("health.stress", values.int("stress"))
            .putLong("health.stressAt", values.long("stressAt"))
            .putInt("health.vitality", values.int("vitality"))
            .putInt("health.sleepDuration", values.int("sleepDuration"))
            .putLong("health.sleepStart", values.long("sleepStart"))
            .putLong("health.sleepEnd", values.long("sleepEnd"))
            .putLong("health.updatedAt", values.long("updatedAt"))
            .apply()
    }

    fun device(context: Context): DeviceValues {
        val values = prefs(context)
        return DeviceValues(
            hasDevice = values.getBoolean("device.has", false),
            name = values.getString("device.name", "") ?: "",
            connected = values.getBoolean("device.connected", false),
            connecting = values.getBoolean("device.connecting", false),
            battery = values.getInt("device.battery", -1),
            charging = values.getBoolean("device.charging", false),
            storageUsed = values.getLong("device.storageUsed", -1),
            storageTotal = values.getLong("device.storageTotal", -1),
            appCount = values.getInt("device.appCount", -1),
            watchfaceCount = values.getInt("device.watchfaceCount", -1),
            updatedAt = values.getLong("device.updatedAt", 0),
        )
    }

    fun health(context: Context): HealthValues {
        val values = prefs(context)
        return HealthValues(
            steps = values.getInt("health.steps", -1),
            activeCalories = values.getInt("health.activeCalories", -1),
            standingHours = values.getInt("health.standingHours", -1),
            heartRate = values.getInt("health.heartRate", -1),
            heartRateAt = values.getLong("health.heartRateAt", -1),
            bloodOxygen = values.getInt("health.bloodOxygen", -1),
            bloodOxygenAt = values.getLong("health.bloodOxygenAt", -1),
            stress = values.getInt("health.stress", -1),
            stressAt = values.getLong("health.stressAt", -1),
            vitality = values.getInt("health.vitality", -1),
            sleepDuration = values.getInt("health.sleepDuration", -1),
            sleepStart = values.getLong("health.sleepStart", -1),
            sleepEnd = values.getLong("health.sleepEnd", -1),
            updatedAt = values.getLong("health.updatedAt", 0),
        )
    }

    private fun Map<*, *>.string(key: String): String = this[key]?.toString() ?: ""
    private fun Map<*, *>.boolean(key: String): Boolean = this[key] == true
    private fun Map<*, *>.int(key: String): Int = (this[key] as? Number)?.toInt() ?: -1
    private fun Map<*, *>.long(key: String): Long = (this[key] as? Number)?.toLong() ?: -1
}

internal data class DeviceValues(
    val hasDevice: Boolean,
    val name: String,
    val connected: Boolean,
    val connecting: Boolean,
    val battery: Int,
    val charging: Boolean,
    val storageUsed: Long,
    val storageTotal: Long,
    val appCount: Int,
    val watchfaceCount: Int,
    val updatedAt: Long,
)

internal data class HealthValues(
    val steps: Int,
    val activeCalories: Int,
    val standingHours: Int,
    val heartRate: Int,
    val heartRateAt: Long,
    val bloodOxygen: Int,
    val bloodOxygenAt: Long,
    val stress: Int,
    val stressAt: Long,
    val vitality: Int,
    val sleepDuration: Int,
    val sleepStart: Long,
    val sleepEnd: Long,
    val updatedAt: Long,
)
