import Flutter
import QuickLook
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var documentPreviewDataSource: LocalDocumentPreview?

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
      if call.method == "shareIncident" {
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "INVALID_INCIDENT", message: "Incident details are missing.", details: nil))
          return
        }
        let title = args["title"] as? String ?? "SalamaSphere incident"
        let text = args["text"] as? String ?? title
        let attachments = args["files"] as? [[String: Any]] ?? []
        var urls: [URL] = []
        do {
          for attachment in attachments {
            guard let fileName = attachment["fileName"] as? String,
                  let bytes = attachment["bytes"] as? FlutterStandardTypedData,
                  !bytes.data.isEmpty else {
              throw NSError(
                domain: "SalamaSphereShare",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "An incident attachment is invalid."]
              )
            }
            let safeName = URL(fileURLWithPath: fileName).lastPathComponent
            let url = FileManager.default.temporaryDirectory
              .appendingPathComponent("incident-\(UUID().uuidString)-\(safeName)")
            try bytes.data.write(to: url, options: .atomic)
            urls.append(url)
          }
        } catch {
          urls.forEach { try? FileManager.default.removeItem(at: $0) }
          result(FlutterError(code: "INCIDENT_SHARE_FAILED", message: error.localizedDescription, details: nil))
          return
        }

        var items: [Any] = urls.map { $0 as NSURL }
        items.append(text)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
          urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        controller.popoverPresentationController?.sourceView = self?.window?.rootViewController?.view
        self?.window?.rootViewController?.present(controller, animated: true)
        result(nil)
        return
      }
      if call.method == "shareMedia" || call.method == "viewMedia" {
        guard let args = call.arguments as? [String: Any],
              let bytes = args["bytes"] as? FlutterStandardTypedData,
              !bytes.data.isEmpty else {
          result(FlutterError(code: "EMPTY_MEDIA", message: "No media bytes were supplied.", details: nil))
          return
        }
        let fileName = URL(
          fileURLWithPath: args["fileName"] as? String ?? "salamasphere-evidence"
        ).lastPathComponent
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
          try bytes.data.write(to: url, options: .atomic)
        } catch {
          result(FlutterError(code: "MEDIA_WRITE_FAILED", message: error.localizedDescription, details: nil))
          return
        }
        if call.method == "viewMedia" {
          let preview = QLPreviewController()
          let dataSource = LocalDocumentPreview(url: url)
          self?.documentPreviewDataSource = dataSource
          preview.dataSource = dataSource
          self?.window?.rootViewController?.present(preview, animated: true)
          result(nil)
          return
        }
        let text = args["text"] as? String ?? args["title"] as? String ?? "SalamaSphere evidence"
        let controller = UIActivityViewController(activityItems: [url, text], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = self?.window?.rootViewController?.view
        self?.window?.rootViewController?.present(controller, animated: true)
        result(nil)
        return
      }
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

  private final class LocalDocumentPreview: NSObject, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
      self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
      1
    }

    func previewController(
      _ controller: QLPreviewController,
      previewItemAt index: Int
    ) -> QLPreviewItem {
      url as NSURL
    }
  }
}
