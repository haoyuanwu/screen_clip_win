#ifndef FLUTTER_PLUGIN_DESKTOP_VISION_OCR_SERVICE_H_
#define FLUTTER_PLUGIN_DESKTOP_VISION_OCR_SERVICE_H_

#include <flutter/encodable_value.h>

#include <cstdint>
#include <string>
#include <vector>

namespace desktop_vision {

/// 识别结果：成功时 value 为通道返回值，失败时 error 为中文错误描述。
struct OcrOutcome {
  bool ok = false;
  std::string error;
  flutter::EncodableMap value;
};

/// 系统是否具备 OCR 能力（是否安装可用的 OCR 语言包）。
bool IsOcrSupported();

/// 引擎信息（引擎名、系统版本、当前语言、支持语言列表）。
flutter::EncodableMap GetOcrEngineInfo();

/// 识别本地图片文件。
OcrOutcome RecognizeImageFile(const std::string& utf8_path,
                              const std::vector<std::string>& languages);

/// 识别内存中的图片字节。
OcrOutcome RecognizeImageBytes(const std::vector<uint8_t>& bytes,
                               const std::vector<std::string>& languages);

}  // namespace desktop_vision

#endif  // FLUTTER_PLUGIN_DESKTOP_VISION_OCR_SERVICE_H_
