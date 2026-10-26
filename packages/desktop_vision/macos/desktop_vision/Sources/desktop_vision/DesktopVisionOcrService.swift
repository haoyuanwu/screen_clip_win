import Foundation
import CoreGraphics
import ImageIO
import Vision

/// macOS 侧 OCR 实现：Apple Vision `VNRecognizeTextRequest`。
///
/// 输出约定（与 Dart 层一致）：
/// - 归一化坐标，原点在**图片左上角**，取值 0~1；
/// - Vision 原始坐标系原点在左下角，此处统一做 y 轴翻转。
enum DesktopVisionOcrService {

  static let engineName = "apple.vision.text"

  static func isSupported() -> Bool {
    if #available(macOS 10.15, *) {
      return true
    }
    return false
  }

  static func supportedLanguages() -> [String] {
    guard #available(macOS 10.15, *) else { return [] }
    let request = VNRecognizeTextRequest()
    if #available(macOS 11.0, *) {
      if let languages = try? request.supportedRecognitionLanguages() {
        return languages
      }
    }
    return []
  }

  static func engineInfo() -> [String: Any] {
    let version = ProcessInfo.processInfo.operatingSystemVersionString
    var defaultLanguage: String? = nil
    if #available(macOS 10.15, *) {
      let request = VNRecognizeTextRequest()
      defaultLanguage = request.recognitionLanguages.first
    }
    return [
      "engine": engineName,
      "version": "macOS \(version), Vision",
      "isAvailable": isSupported(),
      "languageTag": defaultLanguage as Any? ?? NSNull(),
      "supportedLanguages": supportedLanguages(),
    ]
  }

  // MARK: - 入口

  static func recognizeFile(path: String, languages: [String], level: String) throws -> [String: Any] {
    guard #available(macOS 10.15, *) else {
      throw ocrError("当前 macOS 版本过低，Vision 文字识别需要 macOS 10.15 及以上")
    }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ocrError("图片文件不存在：\(path)")
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw ocrError("无法打开图片（格式不支持或文件损坏）：\(path)")
    }
    return try recognize(source: source, languages: languages, level: level)
  }

  static func recognizeBytes(bytes: Data, languages: [String], level: String) throws -> [String: Any] {
    guard #available(macOS 10.15, *) else {
      throw ocrError("当前 macOS 版本过低，Vision 文字识别需要 macOS 10.15 及以上")
    }
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
      throw ocrError("无法解析图片字节（格式不支持或数据损坏）")
    }
    return try recognize(source: source, languages: languages, level: level)
  }

  // MARK: - 核心

  private static func recognize(
    source: CGImageSource,
    languages: [String],
    level: String
  ) throws -> [String: Any] {
    let started = CFAbsoluteTimeGetCurrent()

    guard CGImageSourceGetCount(source) > 0,
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ocrError("图片解码失败")
    }

    let orientation = imageOrientation(from: source) ?? .up

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = (level == "fast") ? .fast : .accurate
    request.usesLanguageCorrection = true
    if #available(macOS 13.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
    }

    if !languages.isEmpty {
      var available: [String] = []
      if #available(macOS 11.0, *) {
        available = (try? request.supportedRecognitionLanguages()) ?? []
      }
      if available.isEmpty {
        request.recognitionLanguages = languages
      } else {
        let filtered = languages.filter { available.contains($0) }
        if filtered.isEmpty {
          throw ocrError(
            "指定的语言不被支持：\(languages.joined(separator: ","))；"
            + "可用语言：\(available.joined(separator: ","))"
          )
        }
        request.recognitionLanguages = filtered
      }
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    try handler.perform([request])

    // 带方向的图片，Vision 输出坐标以"摆正后"的图像为基准
    let rotated = orientation == .left || orientation == .right
      || orientation == .leftMirrored || orientation == .rightMirrored
    let width = rotated ? cgImage.height : cgImage.width
    let height = rotated ? cgImage.width : cgImage.height
    let imageW = Double(width)
    let imageH = Double(height)

    var lines: [[String: Any]] = []
    var textParts: [String] = []

    for observation in (request.results ?? []) {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let lineText = candidate.string
      if lineText.isEmpty { continue }

      let lineBox = normalize(observation.boundingBox, imageW, imageH)

      var words: [[String: Any]] = []
      candidate.string.enumerateSubstrings(
        in: candidate.string.startIndex..<candidate.string.endIndex,
        options: [.byWords, .substringNotRequired]
      ) { _, _, range, _ in
        let token = String(candidate.string[range])
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var box = lineBox
        if let rectObservation = try? candidate.boundingBox(for: range) {
          box = normalize(rectObservation.boundingBox, imageW, imageH)
        }
        words.append([
          "text": token,
          "x": box["x"]!,
          "y": box["y"]!,
          "w": box["w"]!,
          "h": box["h"]!,
          "confidence": Double(candidate.confidence),
        ])
      }

      // Character boxes let the screenshot editor select image text directly.
      var characters: [[String: Any]] = []
      candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex,
        options: [.byComposedCharacterSequences]) { substring, range, _, _ in
        guard let text = substring, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let observation = try? candidate.boundingBox(for: range) else { return }
        let box = normalize(observation.boundingBox, imageW, imageH)
        characters.append(["text": text, "x": box["x"]!, "y": box["y"]!, "w": box["w"]!, "h": box["h"]!])
      }
      lines.append([
        "text": lineText,
        "x": lineBox["x"]!,
        "y": lineBox["y"]!,
        "w": lineBox["w"]!,
        "h": lineBox["h"]!,
        "confidence": Double(candidate.confidence),
        "words": words,
        "characters": characters,
      ])
      textParts.append(lineText)
    }

    let elapsed = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)

    return [
      "text": textParts.joined(separator: "\n"),
      "lines": lines,
      "imageWidth": width,
      "imageHeight": height,
      "engine": engineName,
      "elapsedMs": elapsed,
    ]
  }

  /// Vision 归一化矩形（左下原点）→ 左上原点归一化字典，并裁剪到 0~1。
  private static func normalize(_ rect: CGRect, _ width: Double, _ height: Double) -> [String: Double] {
    func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
    let x = clamp(rect.origin.x)
    let y = clamp(1.0 - rect.origin.y - rect.size.height)
    let w = clamp(rect.size.width)
    let h = clamp(rect.size.height)
    return ["x": x, "y": y, "w": min(w, 1 - x), "h": min(h, 1 - y)]
  }

  private static func imageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let raw = properties[kCGImagePropertyOrientation] as? UInt32 else {
      return nil
    }
    return CGImagePropertyOrientation(rawValue: raw)
  }

  private static func ocrError(_ message: String) -> NSError {
    NSError(
      domain: "desktop_vision",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
