import Foundation
import UserNotifications
#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import AppKit
import FlutterMacOS
#endif

final class SystemNotificationChannel: NSObject, UNUserNotificationCenterDelegate {
    private let channel: FlutterMethodChannel
    private let center = UNUserNotificationCenter.current()
    private var ready = false
    private var pendingLocation: String?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "org.oroncanopy.oronbox/notifications", binaryMessenger: messenger)
        super.init()
        center.delegate = self
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterMethodNotImplemented); return }
            switch call.method {
            case "hasSendPermission":
                center.getNotificationSettings { settings in
                    DispatchQueue.main.async { result(Self.canSend(settings)) }
                }
            case "openSendSettings":
                openSendSettings(result)
            case "getInitialLocation":
                ready = true
                let location = pendingLocation
                pendingLocation = nil
                result(location)
            case "show":
                guard let args = call.arguments as? [String: String],
                      let id = args["id"], let category = args["category"],
                      let title = args["title"], let body = args["body"],
                      let location = args["location"] else { result(false); return }
                center.getNotificationSettings { [weak self] settings in
                    guard let self, Self.canSend(settings) else {
                        DispatchQueue.main.async { result(false) }
                        return
                    }
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    content.sound = .default
                    content.threadIdentifier = category
                    content.userInfo = ["location": location]
                    center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                        DispatchQueue.main.async { result(error == nil) }
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func canSend(_ settings: UNNotificationSettings) -> Bool {
        settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func openSendSettings(_ result: @escaping FlutterResult) {
        center.getNotificationSettings { [center] settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                        DispatchQueue.main.async {
                            if let error {
                                result(FlutterError(code: "NOTIFICATION_PERMISSION", message: error.localizedDescription, details: nil))
                            } else {
                                result(nil)
                            }
                        }
                    }
                    return
                }

                let completed: (Bool) -> Void = { opened in
                    result(opened ? nil : FlutterError(code: "NOTIFICATION_SETTINGS", message: nil, details: nil))
                }
                #if os(iOS)
                let path: String
                if #available(iOS 15.4, *) {
                    path = UIApplication.openNotificationSettingsURLString
                } else {
                    path = UIApplication.openSettingsURLString
                }
                guard let url = URL(string: path) else { completed(false); return }
                UIApplication.shared.open(url, completionHandler: completed)
                #elseif os(macOS)
                let pane: String
                if #available(macOS 13, *) {
                    pane = "com.apple.Notifications-Settings.extension"
                } else {
                    pane = "com.apple.preference.notifications"
                }
                guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { completed(false); return }
                completed(NSWorkspace.shared.open(url))
                #endif
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let location = response.notification.request.content.userInfo["location"] as? String
        DispatchQueue.main.async { [weak self] in
            if let self, let location {
                if ready {
                    channel.invokeMethod("notificationOpened", arguments: location)
                } else {
                    pendingLocation = location
                }
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14, macOS 11, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
