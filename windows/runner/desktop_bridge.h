#pragma once
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <gdiplus.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <commdlg.h>
#include <shlobj.h>
#include <windowsx.h>
#include <algorithm>
#include <fstream>
#include <string>
#include <vector>
#include <memory>
#include "pinned_image_window.h"
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")

// One UI thread owns the channel, selection overlay, tray and hotkey.
class DesktopBridge {
 public:
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  HWND owner;
  std::vector<HWND> pins;
  uint64_t pin_sequence=0;
  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  ULONG_PTR gdiplus = 0;
  NOTIFYICONDATAW tray{};
  bool capture_surface = false, color_surface = false, translation_surface = false;
  LONG_PTR original_style = 0, original_exstyle = 0;
  bool capture_pending = false, was_visible = false;
  bool capture_frame_ready = false, capture_presentation_pending = false;
  RECT selection{}, desktop{};
  HBITMAP background = nullptr;
  std::unique_ptr<Result> pending;
  static constexpr UINT kTray = WM_APP + 71;
  static constexpr UINT kCapture = WM_APP + 72;
  std::string mode;
  struct CaptureWindow {HWND hwnd; DWORD pid; RECT bounds;};
  std::vector<CaptureWindow> capture_windows;
  HWND focused_window=nullptr, previous_above=nullptr, previous_foreground=nullptr, before_tray=nullptr;
  DWORD focused_pid=0;
  bool previously_topmost=false, refreshing_selection=false;

  void RestoreFocusedWindow(bool foreground=true) {
    if(!focused_window) return;
    DWORD pid=0;GetWindowThreadProcessId(focused_window,&pid);
    if(IsWindow(focused_window) && pid==focused_pid) {
      constexpr UINT flags=SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE;
      SetWindowPos(focused_window,previously_topmost?HWND_TOPMOST:HWND_NOTOPMOST,0,0,0,0,flags);
      if(IsWindow(previous_above) && previous_above!=owner &&
          ((GetWindowLongPtr(previous_above,GWL_EXSTYLE)&WS_EX_TOPMOST)!=0)==previously_topmost)
        SetWindowPos(focused_window,previous_above,0,0,0,0,flags);
    }
    focused_window=nullptr;previous_above=nullptr;focused_pid=0;
    if(foreground && IsWindow(previous_foreground) && previous_foreground!=owner)
      SetForegroundWindow(previous_foreground);
  }

  static std::string Utf8(const std::wstring& s) {
    int size = WideCharToMultiByte(CP_UTF8,0,s.c_str(),static_cast<int>(s.size()),nullptr,0,nullptr,nullptr);
    std::string out(size,0); WideCharToMultiByte(CP_UTF8,0,s.c_str(),static_cast<int>(s.size()),out.data(),size,nullptr,nullptr); return out;
  }
  static std::wstring Wide(const std::string& s) {
    int size=MultiByteToWideChar(CP_UTF8,0,s.c_str(),static_cast<int>(s.size()),nullptr,0);
    std::wstring out(size,0); MultiByteToWideChar(CP_UTF8,0,s.c_str(),static_cast<int>(s.size()),out.data(),size); return out;
  }
  DesktopBridge(HWND hwnd, flutter::BinaryMessenger* messenger):owner(hwnd) {
    Gdiplus::GdiplusStartupInput input; Gdiplus::GdiplusStartup(&gdiplus,&input,nullptr);
    channel=std::make_unique<flutter::MethodChannel<Value>>(messenger,"screenclip/desktop",&flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call, std::unique_ptr<Result> result) {
      const auto& method=call.method_name();
      try {
        if(method=="dataDirectory") {
          PWSTR base=nullptr; SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&base);
          if(!base) { result->Error("storage","Cannot locate application data"); return; }
          std::wstring path=std::wstring(base)+L"\\ScreenClip"; CoTaskMemFree(base); CreateDirectoryW(path.c_str(),nullptr); result->Success(Value(Utf8(path)));
        } else if(method=="launchAtLoginStatus" || method=="setLaunchAtLogin") {
          constexpr auto key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
          if(method=="setLaunchAtLogin") {
            HKEY run=nullptr;
            auto status=RegCreateKeyExW(HKEY_CURRENT_USER,key,0,nullptr,0,KEY_SET_VALUE,nullptr,&run,nullptr);
            if(status!=ERROR_SUCCESS) {result->Error("startup","无法修改当前用户的开机启动设置");return;}
            if(std::get<bool>(*call.arguments())) {
              wchar_t path[32768]{};
              auto length=GetModuleFileNameW(nullptr,path,32768);
              if(!length || length>=32768) {RegCloseKey(run);result->Error("startup","无法获取应用路径");return;}
              std::wstring command=L"\""+std::wstring(path)+L"\"";
              status=RegSetValueExW(run,L"ScreenClip",0,REG_SZ,reinterpret_cast<const BYTE*>(command.c_str()),static_cast<DWORD>((command.size()+1)*sizeof(wchar_t)));
            } else {
              status=RegDeleteValueW(run,L"ScreenClip");
              if(status==ERROR_FILE_NOT_FOUND) status=ERROR_SUCCESS;
            }
            RegCloseKey(run);
            if(status!=ERROR_SUCCESS) {result->Error("startup","开机启动设置失败，请重试");return;}
          }
          DWORD size=0;
          bool enabled=RegGetValueW(HKEY_CURRENT_USER,key,L"ScreenClip",RRF_RT_REG_SZ,nullptr,nullptr,&size)==ERROR_SUCCESS;
          // Respect the user's disable action in Windows Startup Apps.
          BYTE approval[12]{}; DWORD approvalSize=sizeof(approval);
          if(RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run",L"ScreenClip",RRF_RT_REG_BINARY,nullptr,approval,&approvalSize)==ERROR_SUCCESS && approvalSize>0 && (approval[0]==3 || approval[0]==7)) enabled=false;
          if(!enabled && approvalSize>0 && (approval[0]==3 || approval[0]==7)) {
            if(method=="setLaunchAtLogin" && std::get<bool>(*call.arguments()))
              ShellExecuteW(owner,L"open",L"ms-settings:startupapps",nullptr,nullptr,SW_SHOWNORMAL);
            DWORD remaining=0;
            if(RegGetValueW(HKEY_CURRENT_USER,key,L"ScreenClip",RRF_RT_REG_SZ,nullptr,nullptr,&remaining)==ERROR_SUCCESS) {
              result->Success(Value("requiresApproval"));return;
            }
          }
          result->Success(Value(enabled?"enabled":"disabled"));
        } else if(method=="registerHotkey") {
          AddTray(); result->Success(Value(RegisterHotKey(owner,71,MOD_CONTROL|MOD_SHIFT|MOD_NOREPEAT,'X')!=0));
        } else if(method=="registerColorHotkey") {
          result->Success(Value(RegisterHotKey(owner,73,MOD_CONTROL|MOD_SHIFT|MOD_NOREPEAT,'C')!=0));
        } else if(method=="present") {
          Present(std::get<std::string>(*call.arguments())); result->Success();
        } else if(method=="captureFrameReady") {
          capture_frame_ready=true;
          if(capture_presentation_pending)Present("capture");
          result->Success();
        } else if(method=="copied") { tray.uFlags=NIF_TIP;wcscpy_s(tray.szTip,L"图片已复制到剪贴板 · Ctrl+Shift+X 再次截图");Shell_NotifyIconW(NIM_MODIFY,&tray);result->Success();
        } else if(method=="dismiss") { capture_presentation_pending=false;capture_frame_ready=false;ShowWindow(owner,SW_HIDE);RestoreFocusedWindow();SetWindowPos(owner,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE); result->Success();
        } else if(method=="capture") {
          if(pending) {result->Error("busy","Capture already in progress");return;}
          RestoreFocusedWindow();refreshing_selection=false;
          capture_frame_ready=false;capture_presentation_pending=false;
          previous_foreground=GetForegroundWindow();
          if(previous_foreground==owner) previous_foreground=before_tray;
          mode=std::get<std::string>(*call.arguments()); pending=std::move(result);
          was_visible=IsWindowVisible(owner)!=0; ShowWindow(owner,SW_HIDE);
          DwmFlush();SetTimer(owner,72,16,nullptr); capture_pending=true;
        } else if(method=="nudgeCursor") {
          const auto* args=std::get_if<flutter::EncodableMap>(call.arguments());
          if(!capture_surface || !args || !IsWindowVisible(owner)) {result->Error("cursor","当前无法微调截图光标");return;}
          auto dxIt=args->find(Value("dx")),dyIt=args->find(Value("dy"));
          if(dxIt==args->end() || dyIt==args->end()) {result->Error("cursor","光标参数无效");return;}
          const auto* dx=std::get_if<int32_t>(&dxIt->second);const auto* dy=std::get_if<int32_t>(&dyIt->second);
          if(!dx || !dy || *dx < -10 || *dx > 10 || *dy < -10 || *dy > 10) {result->Error("cursor","光标参数无效");return;}
          POINT point{};
          if(!GetCursorPos(&point)) {result->Error("cursor","无法获取光标位置");return;}
          point.x=std::clamp(point.x+*dx,desktop.left,desktop.right-1);
          point.y=std::clamp(point.y+*dy,desktop.top,desktop.bottom-1);
          if(!SetCursorPos(point.x,point.y) || !GetCursorPos(&point)) {result->Error("cursor","光标微调失败，请重试");return;}
          result->Success(Value(flutter::EncodableMap{{Value("x"),Value(static_cast<double>(point.x-desktop.left))},{Value("y"),Value(static_cast<double>(point.y-desktop.top))}}));
        } else if(method=="focusCaptureWindow") {
          if(pending) {result->Error("busy","Capture already in progress");return;}
          const int index=std::get<int32_t>(*call.arguments());
          if(!capture_surface || index < -1 || index>=static_cast<int>(capture_windows.size())) {
            result->Error("window","智能选区已失效，请重新截图");return;
          }
          if(index>=0) {
            const auto target=capture_windows[index];DWORD pid=0;
            GetWindowThreadProcessId(target.hwnd,&pid);
            if(!IsWindow(target.hwnd) || !IsWindowVisible(target.hwnd) || IsIconic(target.hwnd) || pid!=target.pid) {
              result->Error("window","目标窗口已关闭或隐藏，请重新截图");return;
            }
            RECT currentBounds{};
            if(FAILED(DwmGetWindowAttribute(target.hwnd,DWMWA_EXTENDED_FRAME_BOUNDS,&currentBounds,sizeof(currentBounds))))GetWindowRect(target.hwnd,&currentBounds);
            if(!EqualRect(&currentBounds,&target.bounds)) {
              result->Error("window","目标窗口位置已变化，请重新截图");return;
            }
            RestoreFocusedWindow(false);
            focused_window=target.hwnd;focused_pid=target.pid;
            previously_topmost=(GetWindowLongPtr(focused_window,GWL_EXSTYLE)&WS_EX_TOPMOST)!=0;
            previous_above=GetWindow(focused_window,GW_HWNDPREV);
            while(previous_above && (previous_above==owner ||
                ((GetWindowLongPtr(previous_above,GWL_EXSTYLE)&WS_EX_TOPMOST)!=0)!=previously_topmost))
              previous_above=GetWindow(previous_above,GW_HWNDPREV);
            if(!SetWindowPos(focused_window,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE)) {
              RestoreFocusedWindow();result->Error("window","无法临时置顶目标窗口");return;
            }
            SetForegroundWindow(focused_window);
          } else RestoreFocusedWindow();
          refreshing_selection=true;pending=std::move(result);
          was_visible=IsWindowVisible(owner)!=0;ShowWindow(owner,SW_HIDE);
          DwmFlush();SetTimer(owner,72,16,nullptr);capture_pending=true;
        } else if(method=="save") {
          const auto& args=std::get<flutter::EncodableMap>(*call.arguments());
          auto bytes=std::get<std::vector<uint8_t>>(args.at(Value("bytes")));
          auto name=Wide(std::get<std::string>(args.at(Value("name"))));
          for(auto& ch:name) if(wcschr(L"<>:\"/\\|?*",ch)) ch=L'_';
          wchar_t path[32768]{}; wcsncpy_s(path,name.c_str(),_TRUNCATE);
          OPENFILENAMEW ofn{}; ofn.lStructSize=sizeof(ofn); ofn.hwndOwner=owner; ofn.lpstrFile=path; ofn.nMaxFile=32768; ofn.lpstrDefExt=L"png";
          ofn.lpstrFilter=L"PNG image\0*.png\0\0"; ofn.Flags=OFN_OVERWRITEPROMPT|OFN_NOCHANGEDIR;
          if(GetSaveFileNameW(&ofn)) {
            std::ofstream out(std::wstring(path),std::ios::binary); out.write(reinterpret_cast<const char*>(bytes.data()),static_cast<std::streamsize>(bytes.size()));
            if(!out) result->Error("save","Could not write image"); else result->Success(Value(Utf8(path)));
          } else result->Success();
        } else if(method=="pin") {
          const auto& args=std::get<flutter::EncodableMap>(*call.arguments());
          const auto& bytes=std::get<std::vector<uint8_t>>(args.at(Value("bytes")));
          auto x=static_cast<LONG>(std::get<double>(args.at(Value("x"))))+desktop.left;
          auto y=static_cast<LONG>(std::get<double>(args.at(Value("y"))))+desktop.top;
          auto width=static_cast<LONG>(std::get<double>(args.at(Value("width"))));
          auto height=static_cast<LONG>(std::get<double>(args.at(Value("height"))));
          BOOL animations=TRUE;SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION,0,&animations,0);
          auto hwnd=PinnedImageWindow::Show(bytes,{x,y,x+width,y+height},animations && std::get<bool>(args.at(Value("animate"))));
          if(!hwnd) {result->Error("pin","无法创建图钉，请重试");return;}
          pins.erase(std::remove_if(pins.begin(),pins.end(),[](HWND item){return !IsWindow(item);}),pins.end());
          const auto id=std::to_string(reinterpret_cast<uintptr_t>(hwnd))+":"+std::to_string(++pin_sequence);
          PinnedImageWindow::SetOcrId(hwnd,id);
          pins.push_back(hwnd);result->Success();
          channel->InvokeMethod("pinCreated",std::make_unique<Value>(flutter::EncodableMap{{Value("id"),Value(id)},{Value("bytes"),Value(bytes)}}));
        } else if(method=="pinOcrResult") {
          const auto& args=std::get<flutter::EncodableMap>(*call.arguments());
          const auto id=std::get<std::string>(args.at(Value("id")));
          const auto text=Wide(std::get<std::string>(args.at(Value("text"))));
          const auto status=std::get<std::string>(args.at(Value("status")));
          std::vector<PinnedImageWindow::TextGlyph> glyphs;
          for(const auto& item:std::get<flutter::EncodableList>(args.at(Value("glyphs")))) {
            const auto& g=std::get<flutter::EncodableMap>(item);
            const int start=std::get<int32_t>(g.at(Value("start"))),end=std::get<int32_t>(g.at(Value("end")));
            if(start<0 || end<=start || end>static_cast<int>(text.size()))continue;
            glyphs.push_back({start,end,std::get<int32_t>(g.at(Value("line"))),std::get<double>(g.at(Value("x"))),std::get<double>(g.at(Value("y"))),std::get<double>(g.at(Value("width"))),std::get<double>(g.at(Value("height")))});
          }
          for(auto hwnd:pins) PinnedImageWindow::SetOcr(hwnd,id,text,glyphs,status=="ready"?1:status=="empty"?2:3);
          result->Success();
        } else if(method=="copy") {
          const auto& bytes=std::get<std::vector<uint8_t>>(*call.arguments());
          HGLOBAL storage=GlobalAlloc(GMEM_MOVEABLE,bytes.size());
          if(!storage) {result->Error("clipboard","Out of memory");return;}
          void* data=GlobalLock(storage); if(!data) {GlobalFree(storage);result->Error("clipboard","Cannot allocate clipboard data");return;}
          memcpy(data,bytes.data(),bytes.size()); GlobalUnlock(storage);
          IStream* stream=nullptr; CreateStreamOnHGlobal(storage,TRUE,&stream);
          if(!stream) {GlobalFree(storage);result->Error("clipboard","Cannot decode image");return;}
          HBITMAP bitmap=nullptr; {Gdiplus::Bitmap image(stream);image.GetHBITMAP(Gdiplus::Color(255,255,255),&bitmap);}
          if(!bitmap || !OpenClipboard(owner)) {if(bitmap) DeleteObject(bitmap);stream->Release();result->Error("clipboard","Clipboard busy. Please try again.");return;}
          EmptyClipboard(); bool success=SetClipboardData(CF_BITMAP,bitmap)!=nullptr;
          if(!success) DeleteObject(bitmap);
          // Preserve lossless PNG for applications that understand this format.
          HGLOBAL png=GlobalAlloc(GMEM_MOVEABLE,bytes.size());
          if(png) {void* ptr=GlobalLock(png);if(ptr){memcpy(ptr,bytes.data(),bytes.size());GlobalUnlock(png);if(!SetClipboardData(RegisterClipboardFormatW(L"PNG"),png)) GlobalFree(png);}else GlobalFree(png);}
          CloseClipboard(); stream->Release();
          if(success) result->Success(); else result->Error("clipboard","Could not copy image");
        } else if(method=="openServiceUrl") {
          const auto* value=std::get_if<std::string>(call.arguments());
          if(!value || (value->rfind("https://",0)!=0 && value->rfind("http://",0)!=0)) {result->Error("url","服务商网址无效");return;}
          if(capture_surface)ShowWindow(owner,SW_HIDE);
          const auto url=Wide(*value);
          auto opened=ShellExecuteW(owner,L"open",url.c_str(),nullptr,nullptr,SW_SHOWNORMAL);
          if(reinterpret_cast<INT_PTR>(opened)<=32) {if(capture_surface)Present("capture");result->Error("url","无法打开服务商网站");}
          else result->Success();
        } else if(method=="openBrowser") {
          const auto* value=std::get_if<std::string>(call.arguments());
          if(!value || (value->rfind("https://",0)!=0 && value->rfind("http://",0)!=0)) {result->Error("url","二维码内容不是网页链接");return;}
          // Restore capture z-order before launching so the later dismiss does
          // not activate the previous app over the newly opened browser.
          RestoreFocusedWindow(false);ShowWindow(owner,SW_HIDE);
          SetWindowPos(owner,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
          const auto url=Wide(*value);
          auto opened=ShellExecuteW(owner,L"open",url.c_str(),nullptr,nullptr,SW_SHOWNORMAL);
          if(reinterpret_cast<INT_PTR>(opened)<=32) {if(capture_surface)Present("capture");result->Error("url","无法打开浏览器，请重试");}
          else result->Success();
        } else if(method=="permissions") {result->Success();}
        else result->NotImplemented();
      } catch(const std::exception& e) { if(result) result->Error("native",e.what()); }
    });
  }
  ~DesktopBridge() {
    RestoreFocusedWindow();
    for(auto hwnd:pins) if(IsWindow(hwnd)) DestroyWindow(hwnd);
    UnregisterHotKey(owner,71);UnregisterHotKey(owner,73); Shell_NotifyIconW(NIM_DELETE,&tray);
    if(background) DeleteObject(background);
    Gdiplus::GdiplusShutdown(gdiplus);
  }
  void AddTray() {
    tray.cbSize=sizeof(tray);tray.hWnd=owner;tray.uID=71;tray.uFlags=NIF_MESSAGE|NIF_ICON|NIF_TIP;
    tray.uCallbackMessage=kTray;tray.hIcon=LoadIconW(GetModuleHandle(nullptr),MAKEINTRESOURCEW(101));
    if(!tray.hIcon) tray.hIcon=LoadIconW(nullptr,IDI_APPLICATION);
    wcscpy_s(tray.szTip,L"定格T截图 | Ctrl+Shift+X");Shell_NotifyIconW(NIM_ADD,&tray);
    tray.uFlags=NIF_INFO;wcscpy_s(tray.szInfoTitle,L"定格T已就绪");wcscpy_s(tray.szInfo,L"按 Ctrl+Shift+X 截图，右键托盘图标打开标注和设置。");tray.dwInfoFlags=NIIF_INFO;Shell_NotifyIconW(NIM_MODIFY,&tray);
  }
  void Present(const std::string& panel) {
    translation_surface=panel=="translation";
    if(!original_style){original_style=GetWindowLongPtr(owner,GWL_STYLE);original_exstyle=GetWindowLongPtr(owner,GWL_EXSTYLE);}
    color_surface=panel=="color";
    if(color_surface) {
      RestoreFocusedWindow();capture_surface=false;
      SetWindowLongPtr(owner,GWL_STYLE,WS_POPUP);SetWindowLongPtr(owner,GWL_EXSTYLE,WS_EX_TOOLWINDOW|WS_EX_TOPMOST);
      POINT point{};GetCursorPos(&point);MONITORINFO monitor{sizeof(monitor)};GetMonitorInfoW(MonitorFromPoint(point,MONITOR_DEFAULTTONEAREST),&monitor);
      const double dpi=GetDpiForWindow(owner)/96.0;const int width=static_cast<int>(300*dpi),height=static_cast<int>(320*dpi);
      const int x=std::clamp(static_cast<int>(point.x+16),static_cast<int>(monitor.rcWork.left),std::max(static_cast<int>(monitor.rcWork.left),static_cast<int>(monitor.rcWork.right)-width));
      const int y=std::clamp(static_cast<int>(point.y+16),static_cast<int>(monitor.rcWork.top),std::max(static_cast<int>(monitor.rcWork.top),static_cast<int>(monitor.rcWork.bottom)-height));
      SetWindowPos(owner,HWND_TOPMOST,x,y,width,height,SWP_FRAMECHANGED|SWP_SHOWWINDOW);ShowWindow(owner,SW_SHOW);SetForegroundWindow(owner);return;
    }
    if(panel=="capture") {
      capture_surface=true;SetWindowLongPtr(owner,GWL_STYLE,WS_POPUP);SetWindowLongPtr(owner,GWL_EXSTYLE,WS_EX_TOOLWINDOW|WS_EX_TOPMOST);
      SetWindowPos(owner,HWND_TOPMOST,desktop.left,desktop.top,desktop.right-desktop.left,desktop.bottom-desktop.top,SWP_FRAMECHANGED|SWP_NOACTIVATE);
      if(!capture_frame_ready) {capture_presentation_pending=true;return;}
      capture_presentation_pending=false;
      ShowWindow(owner,SW_SHOW);SetForegroundWindow(owner);return;
    }
    const HWND foreground=GetForegroundWindow();if(foreground!=owner)before_tray=foreground;
    RestoreFocusedWindow();capture_surface=false;SetWindowLongPtr(owner,GWL_STYLE,original_style);SetWindowLongPtr(owner,GWL_EXSTYLE,original_exstyle);
    SetWindowPos(owner,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE|SWP_FRAMECHANGED);
    int width=panel=="translation"?900:panel=="settings"?560:640;
    int height=panel=="translation"?660:panel=="settings"?560:310;
    double dpi=GetDpiForWindow(owner)/96.0; RECT frame{0,0,static_cast<LONG>(width*dpi),static_cast<LONG>(height*dpi)};
    AdjustWindowRectEx(&frame,static_cast<DWORD>(GetWindowLongPtr(owner,GWL_STYLE)),FALSE,static_cast<DWORD>(GetWindowLongPtr(owner,GWL_EXSTYLE)));width=frame.right-frame.left;height=frame.bottom-frame.top;
    RECT work{};SystemParametersInfoW(SPI_GETWORKAREA,0,&work,0);
    SetWindowPos(owner,HWND_TOP,(work.right+work.left-width)/2,(work.bottom+work.top-height)/2,width,height,SWP_SHOWWINDOW);
    ShowWindow(owner,SW_RESTORE);SetForegroundWindow(owner);
  }
  void Open(const std::string& panel) {channel->InvokeMethod("openPanel",std::make_unique<Value>(panel));}
  void Request(const std::string& value) {channel->InvokeMethod("captureRequested",std::make_unique<Value>(value));}
  bool Handle(UINT message, WPARAM wparam, LPARAM lparam) {
    if(message==WM_GETMINMAXINFO && !capture_surface && !color_surface) {auto info=reinterpret_cast<MINMAXINFO*>(lparam);double dpi=GetDpiForWindow(owner)/96.0;info->ptMinTrackSize={static_cast<LONG>(440*dpi),static_cast<LONG>((translation_surface?480:310)*dpi)};return true;}
    if(message==WM_CLOSE) {channel->InvokeMethod("dismissed",nullptr);ShowWindow(owner,SW_HIDE);RestoreFocusedWindow();return true;}
    if(message==WM_HOTKEY && wparam==73) {Request("color");return true;}
    if(message==WM_HOTKEY && wparam==71) {Request("region");return true;}
    if(message==WM_TIMER && wparam==72 && capture_pending) {KillTimer(owner,72);capture_pending=false;BeginCapture();return true;}
    if(message==kTray) {
      if(lparam==WM_LBUTTONUP) Open("palette");
      if(lparam==WM_RBUTTONUP || lparam==WM_CONTEXTMENU) {
        HMENU menu=CreatePopupMenu();
        AppendMenuW(menu,MF_STRING,1,L"区域截图    Ctrl+Shift+X");AppendMenuW(menu,MF_STRING,7,L"屏幕取色    Ctrl+Shift+C");AppendMenuW(menu,MF_STRING,2,L"窗口截图");AppendMenuW(menu,MF_STRING,3,L"全屏截图（全部显示器）");
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);AppendMenuW(menu,MF_STRING,4,L"截图工具条");AppendMenuW(menu,MF_STRING,5,L"偏好设置");AppendMenuW(menu,MF_SEPARATOR,0,nullptr);AppendMenuW(menu,MF_STRING,6,L"退出定格T");
        POINT pt;GetCursorPos(&pt);before_tray=GetForegroundWindow();SetForegroundWindow(owner);int action=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_RIGHTBUTTON,pt.x,pt.y,0,owner,nullptr);DestroyMenu(menu);PostMessage(owner,WM_NULL,0,0);
        if(action==1)Request("region");if(action==7)Request("color");if(action==2)Request("window");if(action==3)Request("screen");if(action==4)Open("palette");if(action==5)Open("settings");if(action==6)DestroyWindow(owner);
      } return true;
    }
    return false;
  }
  void BeginCapture() {
    desktop={GetSystemMetrics(SM_XVIRTUALSCREEN),GetSystemMetrics(SM_YVIRTUALSCREEN),0,0};
    int w=GetSystemMetrics(SM_CXVIRTUALSCREEN),h=GetSystemMetrics(SM_CYVIRTUALSCREEN);desktop.right=desktop.left+w;desktop.bottom=desktop.top+h;
    HDC screen=GetDC(nullptr),mem=CreateCompatibleDC(screen);background=CreateCompatibleBitmap(screen,w,h);auto old=SelectObject(mem,background);
    BOOL ok=BitBlt(mem,0,0,w,h,screen,desktop.left,desktop.top,SRCCOPY|CAPTUREBLT);SelectObject(mem,old);DeleteDC(mem);ReleaseDC(nullptr,screen);
    if(!ok) {if(refreshing_selection)RestoreFocusedWindow();refreshing_selection=false;pending->Error("capture","Could not capture desktop");pending.reset();if(background){DeleteObject(background);background=nullptr;}if(was_visible)ShowWindow(owner,SW_SHOW);return;}
    selection={0,0,w,h};Finish(true);
  }

  void Finish(bool success) {
    bool frame_ok=false;
    int maxw=desktop.right-desktop.left,maxh=desktop.bottom-desktop.top;
    selection.left=std::clamp(selection.left,0L,static_cast<LONG>(maxw));selection.top=std::clamp(selection.top,0L,static_cast<LONG>(maxh));selection.right=std::clamp(selection.right,0L,static_cast<LONG>(maxw));selection.bottom=std::clamp(selection.bottom,0L,static_cast<LONG>(maxh));
    int w=selection.right-selection.left,h=selection.bottom-selection.top;
    if(!success || w<2 || h<2) {pending->Success();if(was_visible)ShowWindow(owner,SW_SHOW);}
    else {
      Gdiplus::Bitmap source(background,nullptr);std::unique_ptr<Gdiplus::Bitmap> image(source.Clone(selection.left,selection.top,w,h,PixelFormat32bppARGB));
      UINT size=0,count=0;Gdiplus::GetImageEncodersSize(&count,&size);std::vector<BYTE> buffer(size);auto encoders=reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());Gdiplus::GetImageEncoders(count,size,encoders);CLSID png{};
      for(UINT i=0;i<count;i++)if(wcscmp(encoders[i].MimeType,L"image/png")==0)png=encoders[i].Clsid;
      IStream* stream=nullptr;
      if(CreateStreamOnHGlobal(nullptr,TRUE,&stream)==S_OK && image && image->Save(stream,&png,nullptr)==Gdiplus::Ok) {
        STATSTG stat{};stream->Stat(&stat,STATFLAG_NONAME);HGLOBAL memory=nullptr;GetHGlobalFromStream(stream,&memory);
        auto data=static_cast<uint8_t*>(GlobalLock(memory));
        if(data) {std::vector<uint8_t> bytes(data,data+stat.cbSize.QuadPart);GlobalUnlock(memory);flutter::EncodableList windows;
          if(!refreshing_selection) capture_windows.clear();
          struct WindowContext { DesktopBridge* bridge; flutter::EncodableList* list; };WindowContext context{this,&windows};
          EnumWindows([](HWND window,LPARAM parameter)->BOOL {
            auto ctx=reinterpret_cast<WindowContext*>(parameter);if(window==ctx->bridge->owner || !IsWindowVisible(window) || IsIconic(window))return TRUE;
            DWORD pid=0;GetWindowThreadProcessId(window,&pid);if(pid==GetCurrentProcessId())return TRUE;
            wchar_t windowClass[256]{};GetClassNameW(window,windowClass,256);
            if(wcscmp(windowClass,L"Progman")==0 || wcscmp(windowClass,L"WorkerW")==0 || wcscmp(windowClass,L"Shell_TrayWnd")==0 || wcscmp(windowClass,L"Shell_SecondaryTrayWnd")==0)return TRUE;
            if(GetWindowLongPtr(window,GWL_EXSTYLE)&WS_EX_TOOLWINDOW)return TRUE;
            BOOL cloaked=FALSE;DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));if(cloaked)return TRUE;
            RECT r{};if(FAILED(DwmGetWindowAttribute(window,DWMWA_EXTENDED_FRAME_BOUNDS,&r,sizeof(r))))GetWindowRect(window,&r);
            if(r.right-r.left<2||r.bottom-r.top<2)return TRUE;
            if(!ctx->bridge->refreshing_selection)ctx->bridge->capture_windows.push_back({window,pid,r});
            auto& d=ctx->bridge->desktop;
            ctx->list->emplace_back(flutter::EncodableMap{{Value("x"),Value(static_cast<int32_t>(r.left-d.left))},{Value("y"),Value(static_cast<int32_t>(r.top-d.top))},{Value("width"),Value(static_cast<int32_t>(r.right-r.left))},{Value("height"),Value(static_cast<int32_t>(r.bottom-r.top))}});return TRUE;
          },reinterpret_cast<LPARAM>(&context));
          flutter::EncodableList screens;
          struct ScreenContext {RECT desktop; flutter::EncodableList* screens;};ScreenContext screenContext{desktop,&screens};
          EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR monitor,HDC,LPRECT rectangle,LPARAM data)->BOOL {
            auto context=reinterpret_cast<ScreenContext*>(data);MONITORINFO info{};info.cbSize=sizeof(info);if(!GetMonitorInfoW(monitor,&info))return TRUE;
            const auto& r=info.rcMonitor;const auto& d=context->desktop;
            Value display(flutter::EncodableMap{{Value("x"),Value(static_cast<int32_t>(r.left-d.left))},{Value("y"),Value(static_cast<int32_t>(r.top-d.top))},{Value("width"),Value(static_cast<int32_t>(r.right-r.left))},{Value("height"),Value(static_cast<int32_t>(r.bottom-r.top))}});
            if(info.dwFlags&MONITORINFOF_PRIMARY)context->screens->insert(context->screens->begin(),std::move(display));
            else context->screens->emplace_back(std::move(display));return TRUE;
          },reinterpret_cast<LPARAM>(&screenContext));
          frame_ok=true;pending->Success(Value(flutter::EncodableMap{{Value("bytes"),Value(bytes)},{Value("windows"),Value(windows)},{Value("screens"),Value(screens)}}));}
        else pending->Error("capture","Could not read screenshot");
      } else {pending->Error("capture","Could not encode screenshot");if(was_visible)ShowWindow(owner,SW_SHOW);}
      if(stream) stream->Release();
    }
    pending.reset();if(background){DeleteObject(background);background=nullptr;}
    if(refreshing_selection && !frame_ok) {RestoreFocusedWindow();if(was_visible)Present("capture");}
    refreshing_selection=false;
  }
};
