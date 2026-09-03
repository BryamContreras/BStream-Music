import Flutter
import UIKit

/// Exports an existing sandbox file through the native Files document picker.
///
/// Using a source URL avoids copying an entire music-library backup through a
/// Flutter method-channel byte buffer.
final class IOSFileExportPlugin: NSObject, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  private var pendingResult: FlutterResult?
  private var stagedDirectory: URL?
  private weak var documentPicker: UIDocumentPickerViewController?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "saveFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "export_busy",
          message: "Ya hay una exportación en curso.",
          details: nil
        )
      )
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let sourcePath = arguments["sourcePath"] as? String,
      let fileName = arguments["fileName"] as? String,
      let safeFileName = Self.safeFileName(fileName)
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "sourcePath y fileName son obligatorios.",
          details: nil
        )
      )
      return
    }

    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: sourceURL.path,
        isDirectory: &isDirectory
      ),
      !isDirectory.boolValue
    else {
      result(
        FlutterError(
          code: "export_missing",
          message: "No se encontró el archivo para exportar.",
          details: nil
        )
      )
      return
    }

    do {
      let stagedURL = try stage(sourceURL: sourceURL, fileName: safeFileName)
      guard let presenter = Self.activeViewController() else {
        cleanupStagedFile()
        result(
          FlutterError(
            code: "export_unavailable",
            message: "No se pudo abrir el selector de archivos.",
            details: nil
          )
        )
        return
      }

      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forExporting: [stagedURL],
          asCopy: true
        )
      } else {
        picker = UIDocumentPickerViewController(
          url: stagedURL,
          in: .exportToService
        )
      }
      picker.delegate = self
      picker.presentationController?.delegate = self
      pendingResult = result
      documentPicker = picker
      presenter.present(picker, animated: true)
    } catch {
      cleanupStagedFile()
      result(
        FlutterError(
          code: "export_failed",
          message: "No se pudo preparar el archivo para exportar.",
          details: nil
        )
      )
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    finish(with: urls.first?.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(with: nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(with: nil)
  }

  private func stage(sourceURL: URL, fileName: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BStreamExports", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    stagedDirectory = directory
    let destination = directory.appendingPathComponent(fileName)
    do {
      try FileManager.default.linkItem(at: sourceURL, to: destination)
    } catch {
      try FileManager.default.copyItem(at: sourceURL, to: destination)
    }
    return destination
  }

  private func finish(with destinationPath: String?) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    documentPicker?.delegate = nil
    documentPicker = nil
    cleanupStagedFile()
    result(destinationPath)
  }

  private func cleanupStagedFile() {
    guard let directory = stagedDirectory else { return }
    stagedDirectory = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private static func safeFileName(_ proposed: String) -> String? {
    let normalized = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !normalized.isEmpty,
      normalized != ".",
      normalized != "..",
      (normalized as NSString).lastPathComponent == normalized
    else {
      return nil
    }
    return normalized
  }

  private static func activeViewController() -> UIViewController? {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap {
      $0 as? UIWindowScene
    }
    let windows = windowScenes.flatMap(\.windows)
    let root = windows.first(where: \.isKeyWindow)?.rootViewController
      ?? windows.first(where: { !$0.isHidden })?.rootViewController
    return topViewController(from: root)
  }

  private static func topViewController(
    from controller: UIViewController?
  ) -> UIViewController? {
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tabs = controller as? UITabBarController {
      return topViewController(from: tabs.selectedViewController)
    }
    return controller
  }
}
