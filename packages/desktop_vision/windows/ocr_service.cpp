#include "ocr_service.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.System.Profile.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

namespace desktop_vision {
namespace {

using namespace winrt::Windows::Graphics::Imaging;
using namespace winrt::Windows::Media::Ocr;

constexpr char kEngineName[] = "windows.media.ocr";

/// WinRT 调用前需要初始化 COM apartment；MTA 下可用 .get() 同步等待异步任务。
class ApartmentScope {
 public:
  ApartmentScope() {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      initialized_ = true;
    } catch (...) {
      // 已处于其他 apartment 模式时忽略：RPC_E_CHANGED_MODE 不影响后续调用。
    }
  }
  ~ApartmentScope() {
    if (initialized_) {
      try {
        winrt::uninit_apartment();
      } catch (...) {
      }
    }
  }

  ApartmentScope(const ApartmentScope&) = delete;
  ApartmentScope& operator=(const ApartmentScope&) = delete;

 private:
  bool initialized_ = false;
};

OcrOutcome Fail(const std::string& message) {
  OcrOutcome outcome;
  outcome.ok = false;
  outcome.error = message;
  return outcome;
}

double Clamp01(double value) { return std::min(std::max(value, 0.0), 1.0); }

flutter::EncodableMap MakeBox(double x, double y, double w, double h) {
  flutter::EncodableMap box;
  box[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
  box[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
  box[flutter::EncodableValue("w")] = flutter::EncodableValue(w);
  box[flutter::EncodableValue("h")] = flutter::EncodableValue(h);
  return box;
}

OcrEngine CreateEngine(const std::vector<std::string>& languages,
                       std::string* warnings) {
  OcrEngine engine{nullptr};
  for (const auto& tag : languages) {
    try {
      winrt::Windows::Globalization::Language language{winrt::to_hstring(tag)};
      if (OcrEngine::IsLanguageSupported(language)) {
        engine = OcrEngine::TryCreateFromLanguage(language);
        if (engine) {
          break;
        }
      } else if (warnings != nullptr) {
        warnings->append("系统未安装该语言的 OCR 组件: " + tag + "; ");
      }
    } catch (...) {
      if (warnings != nullptr) {
        warnings->append("语言标签无效: " + tag + "; ");
      }
    }
  }
  if (!engine) {
    engine = OcrEngine::TryCreateFromUserProfileLanguages();
  }
  return engine;
}

/// 核心：把解码器产出的位图交给 WinRT OCR，组装统一结构的返回值。
OcrOutcome RecognizeWithDecoder(BitmapDecoder const& decoder,
                                const std::vector<std::string>& languages) {
  const auto started = std::chrono::steady_clock::now();

  std::string warnings;
  OcrEngine engine = CreateEngine(languages, &warnings);
  if (!engine) {
    return Fail(
        "系统没有可用的 OCR 引擎。请在 Windows 设置 → 时间和语言 → 语言 中"
        "为中文/英文安装\"光学字符识别\"可选功能。");
  }
  if (!warnings.empty()) {
    // 只是提示，不阻断识别。
    OutputDebugStringA(("[desktop_vision] " + warnings + "\n").c_str());
  }

  const uint32_t width = decoder.OrientedPixelWidth();
  const uint32_t height = decoder.OrientedPixelHeight();
  if (width == 0 || height == 0) {
    return Fail("图片尺寸无效");
  }

  // WinRT OCR 对超大图有尺寸上限，超过时等比缩小后再识别。
  const uint32_t max_dimension = OcrEngine::MaxImageDimension();
  const uint32_t longest = std::max(width, height);
  SoftwareBitmap bitmap{nullptr};
  try {
    if (max_dimension > 0 && longest > max_dimension) {
      const double ratio = static_cast<double>(max_dimension) /
                           static_cast<double>(longest);
      BitmapTransform transform;
      transform.ScaledWidth(
          std::max<uint32_t>(1, static_cast<uint32_t>(width * ratio)));
      transform.ScaledHeight(
          std::max<uint32_t>(1, static_cast<uint32_t>(height * ratio)));
      transform.InterpolationMode(BitmapInterpolationMode::Fant);
      bitmap = decoder
                   .GetSoftwareBitmapAsync(
                       BitmapPixelFormat::Bgra8, BitmapAlphaMode::Premultiplied,
                       transform, ExifOrientationMode::RespectExifOrientation,
                       ColorManagementMode::DoNotColorManage)
                   .get();
    } else {
      bitmap = decoder
                   .GetSoftwareBitmapAsync(BitmapPixelFormat::Bgra8,
                                           BitmapAlphaMode::Premultiplied)
                   .get();
    }
  } catch (winrt::hresult_error const& e) {
    return Fail("图片解码失败: " + winrt::to_string(e.message()));
  }

  OcrResult ocr_result{nullptr};
  try {
    ocr_result = engine.RecognizeAsync(bitmap).get();
  } catch (winrt::hresult_error const& e) {
    return Fail("OCR 识别失败: " + winrt::to_string(e.message()));
  }

  const double bitmap_width = static_cast<double>(bitmap.PixelWidth());
  const double bitmap_height = static_cast<double>(bitmap.PixelHeight());
  if (bitmap_width <= 0 || bitmap_height <= 0) {
    return Fail("位图尺寸无效");
  }

  flutter::EncodableList lines;
  std::string full_text;

  for (auto const& line : ocr_result.Lines()) {
    double min_x = std::numeric_limits<double>::max();
    double min_y = std::numeric_limits<double>::max();
    double max_x = std::numeric_limits<double>::lowest();
    double max_y = std::numeric_limits<double>::lowest();

    flutter::EncodableList words;
    std::string line_text = winrt::to_string(line.Text());

    for (auto const& word : line.Words()) {
      const auto rect = word.BoundingRect();
      if (rect.Width <= 0 || rect.Height <= 0) {
        continue;
      }
      min_x = std::min(min_x, static_cast<double>(rect.X));
      min_y = std::min(min_y, static_cast<double>(rect.Y));
      max_x = std::max(max_x, static_cast<double>(rect.X + rect.Width));
      max_y = std::max(max_y, static_cast<double>(rect.Y + rect.Height));

      const double nx = Clamp01(static_cast<double>(rect.X) / bitmap_width);
      const double ny = Clamp01(static_cast<double>(rect.Y) / bitmap_height);
      const double nw =
          Clamp01(static_cast<double>(rect.Width) / bitmap_width);
      const double nh =
          Clamp01(static_cast<double>(rect.Height) / bitmap_height);

      flutter::EncodableMap word_map = MakeBox(nx, ny, nw, nh);
      word_map[flutter::EncodableValue("text")] =
          flutter::EncodableValue(winrt::to_string(word.Text()));
      // WinRT OCR 不提供置信度，用 -1 表示"未知"。
      word_map[flutter::EncodableValue("confidence")] =
          flutter::EncodableValue(-1.0);
      words.emplace_back(flutter::EncodableValue(word_map));
    }

    if (words.empty()) {
      continue;
    }

    flutter::EncodableMap line_map = MakeBox(
        Clamp01(min_x / bitmap_width), Clamp01(min_y / bitmap_height),
        Clamp01((max_x - min_x) / bitmap_width),
        Clamp01((max_y - min_y) / bitmap_height));
    line_map[flutter::EncodableValue("text")] =
        flutter::EncodableValue(line_text);
    line_map[flutter::EncodableValue("confidence")] =
        flutter::EncodableValue(-1.0);
    line_map[flutter::EncodableValue("words")] =
        flutter::EncodableValue(words);
    lines.emplace_back(flutter::EncodableValue(line_map));

    if (!full_text.empty()) {
      full_text.append("\n");
    }
    full_text.append(line_text);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - started)
                           .count();

  OcrOutcome outcome;
  outcome.ok = true;
  outcome.value[flutter::EncodableValue("text")] =
      flutter::EncodableValue(full_text);
  outcome.value[flutter::EncodableValue("lines")] =
      flutter::EncodableValue(lines);
  outcome.value[flutter::EncodableValue("imageWidth")] =
      flutter::EncodableValue(static_cast<int32_t>(width));
  outcome.value[flutter::EncodableValue("imageHeight")] =
      flutter::EncodableValue(static_cast<int32_t>(height));
  outcome.value[flutter::EncodableValue("engine")] =
      flutter::EncodableValue(std::string(kEngineName));
  outcome.value[flutter::EncodableValue("elapsedMs")] =
      flutter::EncodableValue(static_cast<int32_t>(elapsed));
  return outcome;
}

std::string WindowsVersionString() {
  try {
    const std::string packed = winrt::to_string(
        winrt::Windows::System::Profile::AnalyticsInfo::VersionInfo()
            .DeviceFamilyVersion());
    const uint64_t value = std::stoull(packed);
    const uint64_t major = (value >> 48) & 0xFFFF;
    const uint64_t minor = (value >> 32) & 0xFFFF;
    const uint64_t build = (value >> 16) & 0xFFFF;
    const uint64_t revision = value & 0xFFFF;
    return "Windows " + std::to_string(major) + "." + std::to_string(minor) +
           "." + std::to_string(build) + "." + std::to_string(revision);
  } catch (...) {
    return "Windows";
  }
}

}  // namespace

bool IsOcrSupported() {
  ApartmentScope scope;
  try {
    return OcrEngine::TryCreateFromUserProfileLanguages() != nullptr;
  } catch (...) {
    return false;
  }
}

flutter::EncodableMap GetOcrEngineInfo() {
  ApartmentScope scope;

  flutter::EncodableMap info;
  info[flutter::EncodableValue("engine")] =
      flutter::EncodableValue(std::string(kEngineName));
  info[flutter::EncodableValue("version")] =
      flutter::EncodableValue(WindowsVersionString() + ", Windows.Media.Ocr");

  flutter::EncodableList supported;
  try {
    for (auto const& language : OcrEngine::AvailableRecognizerLanguages()) {
      supported.emplace_back(
          flutter::EncodableValue(winrt::to_string(language.LanguageTag())));
    }
  } catch (...) {
  }

  std::string current_tag;
  bool available = false;
  try {
    auto engine = OcrEngine::TryCreateFromUserProfileLanguages();
    if (engine) {
      available = true;
      current_tag = winrt::to_string(engine.RecognizerLanguage().LanguageTag());
    }
  } catch (...) {
  }

  info[flutter::EncodableValue("isAvailable")] =
      flutter::EncodableValue(available);
  info[flutter::EncodableValue("languageTag")] =
      available ? flutter::EncodableValue(current_tag)
                : flutter::EncodableValue();
  info[flutter::EncodableValue("supportedLanguages")] =
      flutter::EncodableValue(supported);
  return info;
}

OcrOutcome RecognizeImageFile(const std::string& utf8_path,
                              const std::vector<std::string>& languages) {
  ApartmentScope scope;
  try {
    auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(
                    winrt::to_hstring(utf8_path))
                    .get();
    if (!file) {
      return Fail("无法打开图片文件: " + utf8_path);
    }
    auto stream =
        file.OpenAsync(winrt::Windows::Storage::FileAccessMode::Read).get();
    auto decoder = BitmapDecoder::CreateAsync(stream).get();
    return RecognizeWithDecoder(decoder, languages);
  } catch (winrt::hresult_error const& e) {
    return Fail("读取图片失败: " + winrt::to_string(e.message()) + " (" +
                utf8_path + ")");
  }
}

OcrOutcome RecognizeImageBytes(const std::vector<uint8_t>& bytes,
                               const std::vector<std::string>& languages) {
  ApartmentScope scope;
  if (bytes.empty()) {
    return Fail("图片字节为空");
  }
  try {
    winrt::Windows::Storage::Streams::InMemoryRandomAccessStream stream;
    winrt::Windows::Storage::Streams::DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<uint8_t const>(
        bytes.data(), bytes.data() + bytes.size()));
    writer.StoreAsync().get();
    writer.FlushAsync().get();
    writer.DetachStream();
    stream.Seek(0);
    auto decoder = BitmapDecoder::CreateAsync(stream).get();
    return RecognizeWithDecoder(decoder, languages);
  } catch (winrt::hresult_error const& e) {
    return Fail("解析图片字节失败: " + winrt::to_string(e.message()));
  }
}

}  // namespace desktop_vision
