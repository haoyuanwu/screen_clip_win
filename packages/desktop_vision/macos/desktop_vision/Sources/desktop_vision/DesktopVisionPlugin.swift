import Cocoa
import FlutterMacOS

public class DesktopVisionPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "desktop_vision", binaryMessenger: registrar.messenger)
    let instance = DesktopVisionPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)

    case "isSupported":
      result(DesktopVisionOcrService.isSupported())

    case "getEngineInfo":
      result(DesktopVisionOcrService.engineInfo())

    case "recognizeFile":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "缺少 path 参数", details: nil))
        return
      }
      let languages = args["languages"] as? [String] ?? []
      let level = args["level"] as? String ?? "accurate"
      runAsync(result: result) {
        try DesktopVisionOcrService.recognizeFile(path: path, languages: languages, level: level)
      }

    case "recognizeBytes":
      guard let args = call.arguments as? [String: Any],
            let data = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "缺少 bytes 参数", details: nil))
        return
      }
      let languages = args["languages"] as? [String] ?? []
      let level = args["level"] as? String ?? "accurate"
      runAsync(result: result) {
        try DesktopVisionOcrService.recognizeBytes(bytes: data.data, languages: languages, level: level)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 在后台队列执行识别，回到主线程回传结果，避免阻塞 Flutter 平台线程。
  private func runAsync(
    result: @escaping FlutterResult,
    work: @escaping () throws -> [String: Any]
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch {
        let message = (error as NSError).localizedDescription
        DispatchQueue.main.async {
          result(FlutterError(code: "ocr_failed", message: message, details: nil))
        }
      }
    }
  }
}
