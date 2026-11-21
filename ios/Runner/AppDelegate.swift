import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
  private var nextBackgroundTaskId = 0
  private var systemNotifications: SystemNotificationChannel?

  /// Shared "open with" file channel; SceneDelegate pushes files through it.
  static var fileOpenChannel: FlutterMethodChannel?
  static var pendingOpenFilePath: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "OronBoxBackgroundTasks"
    )
    systemNotifications = SystemNotificationChannel(messenger: registrar.messenger())
    let channel = FlutterMethodChannel(
      name: "org.oroncanopy.oronbox/background_tasks",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "begin", "beginPlugin":
        self.nextBackgroundTaskId += 1
        let id = self.nextBackgroundTaskId
        let task = UIApplication.shared.beginBackgroundTask(
          withName: (call.arguments as? [String: Any])?["label"] as? String
        ) { [weak self] in
          self?.endBackgroundTask(id)
          channel.invokeMethod("expired", arguments: ["ids": [id]])
        }
        guard task != .invalid else {
          result(FlutterError(code: "BACKGROUND_UNAVAILABLE",
                              message: "Background execution could not be started",
                              details: nil))
          return
        }
        self.backgroundTasks[id] = task
        result(id)
      case "end":
        if let id = (call.arguments as? [String: Any])?["id"] as? Int {
          self.endBackgroundTask(id)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let fileChannel = FlutterMethodChannel(
      name: "org.oroncanopy.oronbox/file_open",
      binaryMessenger: registrar.messenger()
    )
    fileChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getInitialFile":
        result(Self.pendingOpenFilePath)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    AppDelegate.fileOpenChannel = fileChannel
  }

  private func endBackgroundTask(_ id: Int) {
    guard let task = backgroundTasks.removeValue(forKey: id),
          task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
  }
}
