#include "include/desktop_vision/desktop_vision_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "desktop_vision_plugin.h"

void DesktopVisionPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  desktop_vision::DesktopVisionPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
