import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.salamasphere/share",
      binaryMessenger: engineBridge.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "shareText",
            let args = call.arguments as? [String: Any],
            let text = args["text"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let title = args["title"] as? String ?? "SalamaSphere"
      let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
      controller.popoverPresentationController?.sourceView = self?.window?.rootViewController?.view
      self?.window?.rootViewController?.present(controller, animated: true)
      result(nil)
      _ = title
    }
  }
}
