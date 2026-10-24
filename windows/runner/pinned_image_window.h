#pragma once
#include <windows.h>
#include <windowsx.h>
#include <gdiplus.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

// Each pin owns only its PNG and decoded bitmap; closing releases both.
class PinnedImageWindow {
 public:
  static HWND Show(const std::vector<uint8_t>& png, RECT source, bool animate) {
    auto pin = new PinnedImageWindow();
    pin->bytes_ = png;
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, png.size());
    if (!memory) { delete pin; return nullptr; }
    auto data = GlobalLock(memory);
    if (!data) { GlobalFree(memory); delete pin; return nullptr; }
    memcpy(data, png.data(), png.size()); GlobalUnlock(memory);
    IStream* stream = nullptr;
    if (CreateStreamOnHGlobal(memory, TRUE, &stream) != S_OK) { GlobalFree(memory); delete pin; return nullptr; }
    {
      Gdiplus::Bitmap decoded(stream);
      if (decoded.GetLastStatus() == Gdiplus::Ok)
        pin->image_.reset(decoded.Clone(0, 0, static_cast<INT>(decoded.GetWidth()), static_cast<INT>(decoded.GetHeight()), PixelFormat32bppPARGB));
    }
    stream->Release();
    if (!pin->image_) { delete pin; return nullptr; }
    WNDCLASSW wc{}; wc.lpfnWndProc = Procedure; wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"DingGeTPinnedImage"; wc.hCursor = LoadCursorW(nullptr, IDC_SIZEALL);
    RegisterClassW(&wc);
    pin->bar_ = static_cast<LONG>(34.0 * GetDpiForSystem()/96.0);
    pin->source_ = source; pin->source_.top -= pin->bar_;
    pin->target_ = pin->Fit(source);
    pin->current_ = animate ? pin->source_ : pin->target_;
    HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"定格T · 图钉暂存", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, wc.hInstance, pin);
    if (!hwnd) { delete pin; return nullptr; }
    pin->Draw(animate ? 230 : 255);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    if (animate) { pin->started_ = GetTickCount64(); SetTimer(hwnd, 1, 16, nullptr); }
    return hwnd;
  }
 private:
  LONG bar_ = 34;
  HWND hwnd_ = nullptr;
  RECT source_{}, target_{}, current_{};
  ULONGLONG started_ = 0;
  std::unique_ptr<Gdiplus::Bitmap> image_;
  std::vector<uint8_t> bytes_;
  int feedback_ = 0;
  RECT Fit(RECT source) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfoW(MonitorFromRect(&source, MONITOR_DEFAULTTONEAREST), &monitor);
    const auto work = monitor.rcWork;
    const double scale = std::min({1.0, (work.right-work.left)*.6/image_->GetWidth(),
        ((work.bottom-work.top)*.6-bar_)/image_->GetHeight()});
    const LONG maxWidth = std::max(1L, static_cast<LONG>(std::min((work.right-work.left)*.6, ((work.bottom-work.top)*.6-bar_)*image_->GetWidth()/image_->GetHeight())));
    const LONG width = std::clamp(static_cast<LONG>(image_->GetWidth()*scale),std::min(static_cast<LONG>(110.0*bar_/34),maxWidth),maxWidth);
    const LONG height = static_cast<LONG>(image_->GetHeight()*(static_cast<double>(width)/image_->GetWidth()))+bar_;
    const LONG left = std::clamp(source.left+20, work.left+8, std::max(work.left+8, work.right-width-8));
    const LONG top = std::clamp(source.top-bar_-16, work.top+8, std::max(work.top+8, work.bottom-height-8));
    return {left, top, left+width, top+height};
  }
  void Draw(BYTE alpha = 255) {
    const int width = current_.right-current_.left, height = current_.bottom-current_.top;
    if (width <= 0 || height <= bar_) return;
    BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !pixels) { if(bitmap) DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr,screen); return; }
    auto old = SelectObject(dc, bitmap);
    {
      Gdiplus::Bitmap surface(width, height, width*4, PixelFormat32bppPARGB, static_cast<BYTE*>(pixels));
      Gdiplus::Graphics g(&surface);
      g.Clear(Gdiplus::Color(0,0,0,0)); g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      g.DrawImage(image_.get(), Gdiplus::Rect(0,bar_,width,height-bar_));
      Gdiplus::SolidBrush background(Gdiplus::Color(242,35,36,40));
      g.FillRectangle(&background,0,0,width,bar_);
      const float uiScale=bar_/34.0f;
      g.ScaleTransform(uiScale,uiScale);
      const int logicalWidth=static_cast<int>(width/uiScale);
      Gdiplus::SolidBrush label(Gdiplus::Color(255,240,240,244));
      Gdiplus::Font font(L"Segoe UI",11,Gdiplus::FontStyleRegular,Gdiplus::UnitPixel);
      g.DrawString(feedback_ ? L"已复制" : L"定格T",-1,&font,Gdiplus::PointF(10,10),&label);
      Gdiplus::Pen pen(Gdiplus::Color(255,235,235,240),1.6f);
      g.DrawRectangle(&pen,logicalWidth-59,12,10,11); g.DrawLine(&pen,logicalWidth-56,8,logicalWidth-46,8);g.DrawLine(&pen,logicalWidth-46,8,logicalWidth-46,18);
      g.DrawLine(&pen,logicalWidth-24,11,logicalWidth-14,21);g.DrawLine(&pen,logicalWidth-14,11,logicalWidth-24,21);
    }
    POINT position{current_.left,current_.top}, origin{}; SIZE size{width,height};
    BLENDFUNCTION blend{AC_SRC_OVER,0,alpha,AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd_,screen,&position,&size,dc,&origin,0,&blend,ULW_ALPHA);
    SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);ReleaseDC(nullptr,screen);
  }
  void Copy() {
    HBITMAP bitmap=nullptr;
    image_->GetHBITMAP(Gdiplus::Color(255,255,255),&bitmap);
    if (!bitmap || !OpenClipboard(hwnd_)) {if(bitmap) DeleteObject(bitmap);return;}
    HGLOBAL png=GlobalAlloc(GMEM_MOVEABLE,bytes_.size());
    if(!png) {CloseClipboard();DeleteObject(bitmap);return;}
    auto ptr=GlobalLock(png);
    if(!ptr){GlobalFree(png);CloseClipboard();DeleteObject(bitmap);return;}
    memcpy(ptr,bytes_.data(),bytes_.size());GlobalUnlock(png);
    EmptyClipboard();
    if(!SetClipboardData(CF_BITMAP,bitmap)) DeleteObject(bitmap);
    if(!SetClipboardData(RegisterClipboardFormatW(L"PNG"),png)) GlobalFree(png);
    CloseClipboard(); feedback_=1;Draw();SetTimer(hwnd_,2,1000,nullptr);
  }
  static LRESULT CALLBACK Procedure(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
    auto self=reinterpret_cast<PinnedImageWindow*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
    if(msg==WM_NCCREATE) {
      self=static_cast<PinnedImageWindow*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
      self->hwnd_=hwnd;SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));
    }
    if(!self) return DefWindowProcW(hwnd,msg,wp,lp);
    switch(msg) {
      case WM_TIMER:
        if(wp==1) {
          double t=std::min(1.0,(GetTickCount64()-self->started_)/240.0);
          double ease=1-std::pow(1-t,3);
          auto lerp=[ease](LONG a,LONG b){return static_cast<LONG>(a+(b-a)*ease);};
          self->current_={lerp(self->source_.left,self->target_.left),lerp(self->source_.top,self->target_.top),lerp(self->source_.right,self->target_.right),lerp(self->source_.bottom,self->target_.bottom)};
          self->Draw(static_cast<BYTE>(230+25*ease));
          if(t>=1) KillTimer(hwnd,1);
        } else {KillTimer(hwnd,2);self->feedback_=0;self->Draw();}
        return 0;
      case WM_LBUTTONDOWN: {
        KillTimer(hwnd,1);
        RECT rect{};GetWindowRect(hwnd,&rect);self->current_=rect;
        int x=static_cast<int>(GET_X_LPARAM(lp)*34.0/self->bar_),y=GET_Y_LPARAM(lp),width=static_cast<int>((rect.right-rect.left)*34.0/self->bar_);
        if(y<self->bar_ && x>width-36) {DestroyWindow(hwnd);return 0;}
        if(y<self->bar_ && x>width-72) {self->Copy();return 0;}
        ReleaseCapture();SendMessageW(hwnd,WM_NCLBUTTONDOWN,HTCAPTION,0);return 0;
      }
      case WM_MOVE: GetWindowRect(hwnd,&self->current_);return 0;
      case WM_MOUSEWHEEL: {
        KillTimer(hwnd,1);
        RECT rect{};GetWindowRect(hwnd,&rect);
        MONITORINFO monitor{sizeof(MONITORINFO)};GetMonitorInfoW(MonitorFromRect(&rect,MONITOR_DEFAULTTONEAREST),&monitor);
        double ratio=static_cast<double>(self->image_->GetHeight())/self->image_->GetWidth();
        int maxWidth=std::min(monitor.rcWork.right-monitor.rcWork.left-16,static_cast<LONG>((monitor.rcWork.bottom-monitor.rcWork.top-self->bar_-16)/ratio));
        int minWidth=std::min(110,maxWidth);
        int width=std::clamp(static_cast<int>((rect.right-rect.left)*(GET_WHEEL_DELTA_WPARAM(wp)>0?1.1:.9)),minWidth,maxWidth);
        int height=static_cast<int>(width*ratio)+self->bar_;
        int left=std::clamp(rect.left,monitor.rcWork.left,std::max(monitor.rcWork.left,monitor.rcWork.right-width));
        int top=std::clamp(rect.top,monitor.rcWork.top,std::max(monitor.rcWork.top,monitor.rcWork.bottom-height));
        self->current_={left,top,left+width,top+height};self->Draw();return 0;
      }
      case WM_KEYDOWN:
        if(wp==VK_ESCAPE || wp==VK_DELETE) {DestroyWindow(hwnd);return 0;}
        if(wp=='C' && GetKeyState(VK_CONTROL)<0) {self->Copy();return 0;}
        break;
      case WM_RBUTTONUP: DestroyWindow(hwnd);return 0;
      case WM_CLOSE: DestroyWindow(hwnd);return 0;
      case WM_NCDESTROY:
        SetWindowLongPtrW(hwnd,GWLP_USERDATA,0);delete self;return DefWindowProcW(hwnd,msg,wp,lp);
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
  }
};
