package org.oroncanopy.oronbox

/** Single registry for channels shared with Flutter.
 *
 * Keeping names outside MainActivity prevents native feature additions from
 * silently inventing a second channel spelling.
 */
object PlatformChannelNames {
    const val FILE_OPEN = "org.oroncanopy.oronbox/file_open"
    const val WEARABLE_LOG = "org.oroncanopy.oronbox/wearable_log"
    const val FIND_PHONE = "org.oroncanopy.oronbox/find_phone"
    const val XMS_WEARABLE = "org.oroncanopy.oronbox/xms_wearable"
    const val BACKGROUND_TASKS = "org.oroncanopy.oronbox/background_tasks"
    const val STATUS_SURFACES = "org.oroncanopy.oronbox/status_surfaces"
    const val LOGS = "org.oroncanopy.oronbox/logs"
    const val INSTALLER = "org.oroncanopy.oronbox/installer"
    const val CLASSIC_SPP = "org.oroncanopy.oronbox/classic_spp"
    const val CLASSIC_SPP_EVENTS = "org.oroncanopy.oronbox/classic_spp/events"
    const val CLASSIC_SPP_SCAN_EVENTS = "org.oroncanopy.oronbox/classic_spp/scan_events"
    const val XIAOMI_SCREENSHOT = "org.oroncanopy.oronbox/xiaomi_screenshot"
    const val DEVICE_RECORDINGS = "org.oroncanopy.oronbox/device_recordings"
    const val PUBLIC_BACKUPS = "org.oroncanopy.oronbox/public_backups"
    const val NOTIFICATIONS = "org.oroncanopy.oronbox/notifications"
    const val SYSTEM_INFO = "org.oroncanopy.oronbox/system_info"
}
