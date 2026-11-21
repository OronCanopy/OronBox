import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  private var systemNotifications: SystemNotificationChannel?
  private var rfcommChannel: MacOSRfcommChannel?

  override func awakeFromNib() {
    let noGui = ProcessInfo.processInfo.arguments.contains("--nogui")
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    Self.registerWindowHandle(flutterViewController)
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
      Self.registerWindowHandle(controller)
    }
    rfcommChannel = MacOSRfcommChannel(
      messenger: flutterViewController.engine.binaryMessenger
    )
    if !noGui {
      systemNotifications = SystemNotificationChannel(messenger: flutterViewController.engine.binaryMessenger)
    }
    let fileChannel = FlutterMethodChannel(
      name: "org.oroncanopy.oronbox/file_open",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    fileChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getInitialFile":
        result(AppDelegate.activateFileOpenDelivery())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    AppDelegate.fileOpenChannel = fileChannel

    let windowChannel = FlutterMethodChannel(
      name: "org.oroncanopy.oronbox/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel.setMethodCallHandler { call, result in
      guard call.method == "setIcon" else {
        result(FlutterMethodNotImplemented); return
      }
      guard let encoded = call.arguments as? String,
            let data = Data(base64Encoded: encoded),
            let image = NSImage(data: data) else {
        result(FlutterError(code: "INVALID_ICON", message: "Invalid icon data", details: nil)); return
      }
      let canvas = NSImage(size: NSSize(width: 1024, height: 1024))
      canvas.lockFocus()
      NSGraphicsContext.current?.imageInterpolation = .high
      let side = 840.0
      image.draw(
        in: NSRect(x: (1024.0 - side) / 2.0, y: (1024.0 - side) / 2.0, width: side, height: side),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1.0
      )
      canvas.unlockFocus()
      NSApp.applicationIconImage = canvas
      result(nil)
    }

    super.awakeFromNib()
    if noGui {
      orderOut(nil)
    }
  }

  private static func registerWindowHandle(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "org.oroncanopy.oronbox/window_handle",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak controller] call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let window = controller?.view.window else {
        result(FlutterError(code: "WINDOW_UNAVAILABLE", message: "Window unavailable", details: nil))
        return
      }
      result(Int64(Int(bitPattern: Unmanaged.passUnretained(window).toOpaque())))
    }
  }
}
