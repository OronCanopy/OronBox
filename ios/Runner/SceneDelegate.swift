import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// Copies an "open with" file URL into tmp and returns the local path.
  private static func localPath(for url: URL) -> String? {
    guard url.isFileURL else { return nil }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("file_open", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let target = tmp.appendingPathComponent(url.lastPathComponent)
    do {
      if fm.fileExists(atPath: target.path) {
        try? fm.removeItem(at: target)
      }
      try fm.copyItem(at: url, to: target)
      return target.path
    } catch {
      return url.path
    }
  }

  private static func handle(_ url: URL) {
    guard let path = localPath(for: url) else { return }
    AppDelegate.pendingOpenFilePath = path
    AppDelegate.fileOpenChannel?.invokeMethod("openFile", arguments: path)
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Cold start: the channel is not registered yet, so stash the path and
    // let Dart pull it with getInitialFile after the first frame.
    for context in connectionOptions.urlContexts where context.url.isFileURL {
      if let path = localPath(for: context.url) {
        AppDelegate.pendingOpenFilePath = path
      }
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts where context.url.isFileURL {
      Self.handle(context.url)
    }
  }
}
