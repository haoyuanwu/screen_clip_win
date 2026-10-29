#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  bridge_ = std::make_unique<DesktopBridge>(GetHandle(), flutter_controller_->engine()->messenger());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Resident utility: expose UI only through the tray or capture completion.
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::PrepareKeyboardMessage(MSG& message) {
  if (!bridge_ || bridge_->text_input_active ||
      (!bridge_->capture_surface && !bridge_->color_surface) ||
      GetAncestor(message.hwnd, GA_ROOT) != GetHandle()) return;
  if (message.message == WM_KEYDOWN && message.wParam == VK_PROCESSKEY) {
    // IMM only exposes the original key before TranslateMessage. Recover it for
    // capture shortcuts; text annotations keep the normal IME composition path.
    const UINT key = ImmGetVirtualKey(message.hwnd);
    if (key && key != VK_PROCESSKEY) {
      if (HIMC context = ImmGetContext(message.hwnd)) {
        ImmNotifyIME(context, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
        ImmReleaseContext(message.hwnd, context);
      }
      message.wParam = key;
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Restart Manager uses session messages, not the resident window's close action.
  // A query or a canceled shutdown must never terminate the application.
  if (message == WM_QUERYENDSESSION) return TRUE;
  if (message == WM_ENDSESSION) {
    if (wparam) DestroyWindow(hwnd);
    return 0;
  }
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE && bridge_) {
    // Keep keyboard input in the Flutter view when returning to capture.
    SetFocus(flutter_controller_->view()->GetNativeWindow());
    bridge_->UpdateInputMode();
  }
  if (message == WM_DPICHANGED && bridge_ && bridge_->capture_surface) {
    // Update the engine DPI but keep the frozen virtual desktop's physical bounds.
    flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    const auto& desktop = bridge_->desktop;
    SetWindowPos(hwnd, HWND_TOPMOST, desktop.left, desktop.top,
                 desktop.right - desktop.left, desktop.bottom - desktop.top,
                 SWP_NOACTIVATE);
    return 0;
  }
  if (bridge_ && bridge_->Handle(message, wparam, lparam)) return 0;
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
