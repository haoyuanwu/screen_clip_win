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
  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  ULONG_PTR gdiplus = 0;
  NOTIFYICONDATAW tray{};
  bool capture_surface = false;
  LONG_PTR original_style = 0, original_exstyle = 0;
  bool capture_pending = false, was_visible = false;
  RECT selection{}, desktop{};
  HBITMAP background = nullptr;
  std::unique_ptr<Result> pending;
  static constexpr UINT kTray = WM_APP + 71;
  static constexpr UINT kCapture = WM_APP + 72;
  std::string mode;

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
        } else if(method=="present") {
          Present(std::get<std::string>(*call.arguments())); result->Success();
        } else if(method=="copied") { tray.uFlags=NIF_TIP;wcscpy_s(tray.szTip,L"图片已复制到剪贴板 · Ctrl+Shift+X 再次截图");Shell_NotifyIconW(NIM_MODIFY,&tray);result->Success();
        } else if(method=="dismiss") { ShowWindow(owner,SW_HIDE);SetWindowPos(owner,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE); result->Success();
        } else if(method=="capture") {
          if(pending) {result->Error("busy","Capture already in progress");return;}
          mode=std::get<std::string>(*call.arguments()); pending=std::move(result);
          was_visible=IsWindowVisible(owner)!=0; ShowWindow(owner,SW_HIDE);
          SetTimer(owner,72,220,nullptr); capture_pending=true;
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
          pins.push_back(hwnd);result->Success();
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
        } else if(method=="permissions") {result->Success();}
        else result->NotImplemented();
      } catch(const std::exception& e) { if(result) result->Error("native",e.what()); }
    });
  }
  ~DesktopBridge() {
    for(auto hwnd:pins) if(IsWindow(hwnd)) DestroyWindow(hwnd);
    UnregisterHotKey(owner,71); Shell_NotifyIconW(NIM_DELETE,&tray);
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
    if(!original_style){original_style=GetWindowLongPtr(owner,GWL_STYLE);original_exstyle=GetWindowLongPtr(owner,GWL_EXSTYLE);}
    if(panel=="capture") {
      capture_surface=true;SetWindowLongPtr(owner,GWL_STYLE,WS_POPUP);SetWindowLongPtr(owner,GWL_EXSTYLE,WS_EX_TOOLWINDOW|WS_EX_TOPMOST);
      SetWindowPos(owner,HWND_TOPMOST,desktop.left,desktop.top,desktop.right-desktop.left,desktop.bottom-desktop.top,SWP_FRAMECHANGED|SWP_SHOWWINDOW);
      ShowWindow(owner,SW_SHOW);SetForegroundWindow(owner);return;
    }
    capture_surface=false;SetWindowLongPtr(owner,GWL_STYLE,original_style);SetWindowLongPtr(owner,GWL_EXSTYLE,original_exstyle);
    SetWindowPos(owner,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE|SWP_FRAMECHANGED);
    int width=panel=="settings"?560:640;
    int height=panel=="settings"?560:310;
    double dpi=GetDpiForWindow(owner)/96.0; RECT frame{0,0,static_cast<LONG>(width*dpi),static_cast<LONG>(height*dpi)};
    AdjustWindowRectEx(&frame,static_cast<DWORD>(GetWindowLongPtr(owner,GWL_STYLE)),FALSE,static_cast<DWORD>(GetWindowLongPtr(owner,GWL_EXSTYLE)));width=frame.right-frame.left;height=frame.bottom-frame.top;
    RECT work{};SystemParametersInfoW(SPI_GETWORKAREA,0,&work,0);
    SetWindowPos(owner,HWND_TOP,(work.right+work.left-width)/2,(work.bottom+work.top-height)/2,width,height,SWP_SHOWWINDOW);
    ShowWindow(owner,SW_RESTORE);SetForegroundWindow(owner);
  }
  void Open(const std::string& panel) {channel->InvokeMethod("openPanel",std::make_unique<Value>(panel));}
  void Request(const std::string& value) {channel->InvokeMethod("captureRequested",std::make_unique<Value>(value));}
  bool Handle(UINT message, WPARAM wparam, LPARAM lparam) {
    if(message==WM_GETMINMAXINFO && !capture_surface) {auto info=reinterpret_cast<MINMAXINFO*>(lparam);double dpi=GetDpiForWindow(owner)/96.0;info->ptMinTrackSize={static_cast<LONG>(440*dpi),static_cast<LONG>(310*dpi)};return true;}
    if(message==WM_CLOSE) {channel->InvokeMethod("dismissed",nullptr);ShowWindow(owner,SW_HIDE);return true;}
    if(message==WM_HOTKEY && wparam==71) {Request("region");return true;}
    if(message==WM_TIMER && wparam==72 && capture_pending) {KillTimer(owner,72);capture_pending=false;BeginCapture();return true;}
    if(message==kTray) {
      if(lparam==WM_LBUTTONUP) Open("palette");
      if(lparam==WM_RBUTTONUP || lparam==WM_CONTEXTMENU) {
        HMENU menu=CreatePopupMenu();
        AppendMenuW(menu,MF_STRING,1,L"区域截图    Ctrl+Shift+X");AppendMenuW(menu,MF_STRING,2,L"窗口截图");AppendMenuW(menu,MF_STRING,3,L"全屏截图（全部显示器）");
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);AppendMenuW(menu,MF_STRING,4,L"截图工具条");AppendMenuW(menu,MF_STRING,5,L"偏好设置");AppendMenuW(menu,MF_SEPARATOR,0,nullptr);AppendMenuW(menu,MF_STRING,6,L"退出定格T");
        POINT pt;GetCursorPos(&pt);SetForegroundWindow(owner);int action=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_RIGHTBUTTON,pt.x,pt.y,0,owner,nullptr);DestroyMenu(menu);PostMessage(owner,WM_NULL,0,0);
        if(action==1)Request("region");if(action==2)Request("window");if(action==3)Request("screen");if(action==4)Open("palette");if(action==5)Open("settings");if(action==6)DestroyWindow(owner);
      } return true;
    }
    return false;
  }
  void BeginCapture() {
    desktop={GetSystemMetrics(SM_XVIRTUALSCREEN),GetSystemMetrics(SM_YVIRTUALSCREEN),0,0};
    int w=GetSystemMetrics(SM_CXVIRTUALSCREEN),h=GetSystemMetrics(SM_CYVIRTUALSCREEN);desktop.right=desktop.left+w;desktop.bottom=desktop.top+h;
    HDC screen=GetDC(nullptr),mem=CreateCompatibleDC(screen);background=CreateCompatibleBitmap(screen,w,h);auto old=SelectObject(mem,background);
    BOOL ok=BitBlt(mem,0,0,w,h,screen,desktop.left,desktop.top,SRCCOPY|CAPTUREBLT);SelectObject(mem,old);DeleteDC(mem);ReleaseDC(nullptr,screen);
    if(!ok) {pending->Error("capture","Could not capture desktop");pending.reset();if(background){DeleteObject(background);background=nullptr;}if(was_visible)ShowWindow(owner,SW_SHOW);return;}
    selection={0,0,w,h};Finish(true);
  }

  void Finish(bool success) {
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
          struct WindowContext { DesktopBridge* bridge; flutter::EncodableList* list; };WindowContext context{this,&windows};
          EnumWindows([](HWND window,LPARAM parameter)->BOOL {
            auto ctx=reinterpret_cast<WindowContext*>(parameter);if(window==ctx->bridge->owner || !IsWindowVisible(window) || IsIconic(window))return TRUE;
            if(GetWindowLongPtr(window,GWL_EXSTYLE)&WS_EX_TOOLWINDOW)return TRUE;
            BOOL cloaked=FALSE;DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));if(cloaked)return TRUE;
            RECT r{};if(FAILED(DwmGetWindowAttribute(window,DWMWA_EXTENDED_FRAME_BOUNDS,&r,sizeof(r))))GetWindowRect(window,&r);
            if(r.right-r.left<2||r.bottom-r.top<2)return TRUE;
            auto& d=ctx->bridge->desktop;
            ctx->list->emplace_back(flutter::EncodableMap{{Value("x"),Value(static_cast<int32_t>(r.left-d.left))},{Value("y"),Value(static_cast<int32_t>(r.top-d.top))},{Value("width"),Value(static_cast<int32_t>(r.right-r.left))},{Value("height"),Value(static_cast<int32_t>(r.bottom-r.top))}});return TRUE;
          },reinterpret_cast<LPARAM>(&context));
          flutter::EncodableList screens;
          struct ScreenContext {RECT desktop; flutter::EncodableList* screens;};ScreenContext screenContext{desktop,&screens};
          EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR monitor,HDC,LPRECT rectangle,LPARAM data)->BOOL {
            auto context=reinterpret_cast<ScreenContext*>(data);MONITORINFO info{};info.cbSize=sizeof(info);if(!GetMonitorInfoW(monitor,&info))return TRUE;
            const auto& r=info.rcMonitor;const auto& d=context->desktop;
            context->screens->emplace_back(flutter::EncodableMap{{Value("x"),Value(static_cast<int32_t>(r.left-d.left))},{Value("y"),Value(static_cast<int32_t>(r.top-d.top))},{Value("width"),Value(static_cast<int32_t>(r.right-r.left))},{Value("height"),Value(static_cast<int32_t>(r.bottom-r.top))}});return TRUE;
          },reinterpret_cast<LPARAM>(&screenContext));
          pending->Success(Value(flutter::EncodableMap{{Value("bytes"),Value(bytes)},{Value("windows"),Value(windows)},{Value("screens"),Value(screens)}}));}
        else pending->Error("capture","Could not read screenshot");
      } else {pending->Error("capture","Could not encode screenshot");if(was_visible)ShowWindow(owner,SW_SHOW);}
      if(stream) stream->Release();
    }
    pending.reset();if(background){DeleteObject(background);background=nullptr;}
  }
};
