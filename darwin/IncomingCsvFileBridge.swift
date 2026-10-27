import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Copies document-provider files while their security scope is still valid.
/// All IO, coordination and size checks run on one utility worker.
final class IncomingCsvFileBridge {
  static let shared = IncomingCsvFileBridge()
  private let worker = DispatchQueue(label: "com.bstream.incomingCsv", qos: .utility)
  private var channel: FlutterMethodChannel?
  private var pending: [String: [String: Any]] = [:]
  private var order: [String] = []
  private var owned: [String: URL] = [:]
  private var sources: [String: String] = [:]
  private var activeSources: Set<String> = []
  private var ready = false
  private let limit = 16 * 1024 * 1024

  func attach(messenger: FlutterBinaryMessenger) {
    ready = false
    let bridge = FlutterMethodChannel(name: "bstream_music/incoming_csv", binaryMessenger: messenger)
    bridge.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "start":
        self.ready = true
        let events = self.order.compactMap { self.pending[$0] }
        self.pending.removeAll()
        self.order.removeAll()
        result(events)
      case "stop":
        self.ready = false
        result(nil)
      case "release":
        let arguments = call.arguments as? [String: Any]
        if let id = arguments?["id"] as? String, let directory = self.owned.removeValue(forKey: id) {
          if let source = self.sources.removeValue(forKey: id) { self.activeSources.remove(source) }
          self.worker.async { try? FileManager.default.removeItem(at: directory) }
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    channel = bridge
  }

  @discardableResult
  func accept(_ url: URL) -> Bool {
    guard url.isFileURL, url.pathExtension.lowercased() == "csv" else { return false }
    guard activeSources.insert(url.absoluteString).inserted else { return true }
    let id = UUID().uuidString
    sources[id] = url.absoluteString
    let protectedDirectories = Set(owned.values.map { $0.path })
    // Acquire before returning to the OS callback and keep it through the copy.
    let scoped = url.startAccessingSecurityScopedResource()
    worker.async {
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      var destinationDirectory: URL?
      do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-csv", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
          if protectedDirectories.contains(entry.path) { continue }
          if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
             modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        destinationDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The original basename is meaningful: the CSV importer uses it as the
        // default playlist name. Its enclosing directory supplies uniqueness.
        let name = url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
          do {
            let length = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard length <= self.limit else { throw CsvOpenError.tooLarge }
            guard let input = InputStream(url: source), let output = OutputStream(url: destination, append: false) else {
              throw CsvOpenError.unreadable
            }
            input.open()
            output.open()
            defer { input.close(); output.close() }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            var total = 0
            while true {
              let count = input.read(&buffer, maxLength: buffer.count)
              if count < 0 { throw input.streamError ?? CsvOpenError.unreadable }
              if count == 0 { break }
              total += count
              guard total <= self.limit else { throw CsvOpenError.tooLarge }
              try buffer.withUnsafeBufferPointer { bytes in
                var offset = 0
                while offset < count {
                  let written = output.write(bytes.baseAddress!.advanced(by: offset), maxLength: count - offset)
                  if written <= 0 { throw output.streamError ?? CsvOpenError.unreadable }
                  offset += written
                }
              }
            }
          } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        DispatchQueue.main.async {
          self.owned[id] = directory
          self.publish(id, event: ["id": id, "path": destination.path, "name": name,
                                  "source": url.absoluteString, "temporary": true])
        }
      } catch {
        if let directory = destinationDirectory { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.main.async {
          if let source = self.sources.removeValue(forKey: id) { self.activeSources.remove(source) }
          self.publish(id, event: ["id": id, "error": "csv_open_failed", "message": error.localizedDescription])
        }
      }
    }
    return true
  }

  private func publish(_ id: String, event: [String: Any]) {
    pending[id] = event
    order.append(id)
    guard ready, let channel else { return }
    channel.invokeMethod("open", arguments: event) { result in
      // A missing receiver retains the event for the next start handshake.
      if result is FlutterError || (result as AnyObject?) === (FlutterMethodNotImplemented as AnyObject) { return }
      self.pending.removeValue(forKey: id)
      self.order.removeAll { $0 == id }
    }
  }
}

private enum CsvOpenError: LocalizedError {
  case tooLarge, unreadable
  var errorDescription: String? {
    switch self {
    case .tooLarge: return "CSV exceeds 16 MiB"
    case .unreadable: return "Cannot read CSV"
    }
  }
}
