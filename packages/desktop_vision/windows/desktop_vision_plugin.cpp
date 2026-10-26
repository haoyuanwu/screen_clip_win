#include "desktop_vision_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <VersionHelpers.h>

#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "ocr_service.h"

namespace desktop_vision {
namespace {

using EncodableResult =
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

std::vector<std::string> ReadLanguages(
    const flutter::EncodableMap& arguments) {
  std::vector<std::string> languages;
  auto it = arguments.find(flutter::EncodableValue("languages"));
  if (it == arguments.end()) {
    return languages;
  }
  const auto* list = std::get_if<flutter::EncodableList>(&it->second);
  if (list == nullptr) {
    return languages;
  }
  for (const auto& item : *list) {
    if (const auto* tag = std::get_if<std::string>(&item)) {
      if (!tag->empty()) {
        languages.push_back(*tag);
      }
    }
  }
  return languages;
}

/// 在后台线程执行识别，避免阻塞 Flutter 平台线程（大图推理可达数百毫秒）。
void RunInBackground(EncodableResult result,
                     std::vector<uint8_t> bytes,
                     std::string path,
                     std::vector<std::string> languages) {
  std::thread worker([result, bytes = std::move(bytes), path = std::move(path),
                      languages = std::move(languages)]() {
    OcrOutcome outcome;
    if (!bytes.empty()) {
      outcome = RecognizeImageBytes(bytes, languages);
    } else {
      outcome = RecognizeImageFile(path, languages);
    }
    if (outcome.ok) {
      result->Success(flutter::EncodableValue(outcome.value));
    } else {
      result->Error("ocr_failed", outcome.error);
    }
  });
  worker.detach();
}

}  // namespace

// static
void DesktopVisionPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "desktop_vision",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<DesktopVisionPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

DesktopVisionPlugin::DesktopVisionPlugin() {}

DesktopVisionPlugin::~DesktopVisionPlugin() {}

void DesktopVisionPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string &method = method_call.method_name();

  if (method == "getPlatformVersion") {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
    return;
  }

  if (method == "isSupported") {
    result->Success(flutter::EncodableValue(IsOcrSupported()));
    return;
  }

  if (method == "getEngineInfo") {
    result->Success(flutter::EncodableValue(GetOcrEngineInfo()));
    return;
  }

  if (method == "recognizeFile" || method == "recognizeBytes") {
    const auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments == nullptr) {
      result->Error("bad_args", "参数格式错误");
      return;
    }

    std::vector<std::string> languages = ReadLanguages(*arguments);
    EncodableResult shared(std::move(result));

    if (method == "recognizeFile") {
      auto path_it = arguments->find(flutter::EncodableValue("path"));
      if (path_it == arguments->end() ||
          std::get_if<std::string>(&path_it->second) == nullptr) {
        shared->Error("bad_args", "缺少 path 参数");
        return;
      }
      RunInBackground(shared, std::vector<uint8_t>(),
                      *std::get_if<std::string>(&path_it->second),
                      std::move(languages));
      return;
    }

    auto bytes_it = arguments->find(flutter::EncodableValue("bytes"));
    if (bytes_it == arguments->end()) {
      shared->Error("bad_args", "缺少 bytes 参数");
      return;
    }
    const auto *bytes = std::get_if<std::vector<uint8_t>>(&bytes_it->second);
    if (bytes == nullptr || bytes->empty()) {
      shared->Error("bad_args", "bytes 参数为空或格式错误");
      return;
    }
    RunInBackground(shared, *bytes, std::string(), std::move(languages));
    return;
  }

  result->NotImplemented();
}

}  // namespace desktop_vision
