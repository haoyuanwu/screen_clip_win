#pragma once
#include <windows.h>
#include <windowsx.h>
#include <gdiplus.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>
#include <string>
#include <map>

// Each pin owns only its PNG and decoded bitmap; closing releases both.
class PinnedImageWindow {
 public:
  struct TextGlyph {int start,end,line;double x,y,width,height;};
  static void SetOcr(HWND hwnd, const std::string& id, const std::wstring& text, std::vector<TextGlyph> glyphs, int status) {
    wchar_t name[64]{};
    if(!IsWindow(hwnd) || !GetClassNameW(hwnd,name,64) || wcscmp(name,L"DingGeTPinnedImage")!=0) return;
    auto self=reinterpret_cast<PinnedImageWindow*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
    if(!self || self->ocr_id_!=id) return;
    self->text_=text;self->glyphs_=std::move(glyphs);self->ocr_status_=status;
    self->reveal_started_=GetTickCount64();self->reveal_=1;
    SetTimer(hwnd,4,30,nullptr);self->Draw();
  }
  static void SetOcrId(HWND hwnd, const std::string& id) {
    auto self=reinterpret_cast<PinnedImageWindow*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
    if(self) self->ocr_id_=id;
  }
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
    pin->source_ = source; pin->animate_ = animate;
    pin->target_ = pin->Fit(source);
    pin->current_ = animate ? pin->source_ : pin->target_;
    HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"定格T · 图钉暂存", WS_POPUP, pin->current_.left, pin->current_.top, pin->current_.right-pin->current_.left, pin->current_.bottom-pin->current_.top, nullptr, nullptr, wc.hInstance, pin);
    if (!hwnd) { delete pin; return nullptr; }
    // WM_MOVE during CreateWindowEx updates current_; restore the intended frame
    // after applying the actual target monitor's DPI, including reduced motion.
    pin->bar_ = static_cast<LONG>(34.0 * GetDpiForWindow(hwnd)/96.0);
    pin->target_ = pin->Fit(source);
    pin->current_ = animate ? pin->source_ : pin->target_;
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
  ULONGLONG bar_started_ = 0;
  double bar_opacity_ = 0, bar_from_ = 0, bar_target_ = 0;
  bool hovering_ = false, animate_ = true;
  std::unique_ptr<Gdiplus::Bitmap> image_;
  std::unique_ptr<Gdiplus::Bitmap> glass_;
  int glass_width_ = 0, glass_height_ = 0;
  std::vector<uint8_t> bytes_;
  int feedback_ = 0;
  std::string ocr_id_;
  std::wstring text_;
  std::vector<TextGlyph> glyphs_;
  int ocr_status_=0, anchor_=0, extent_=0;
  bool selecting_text_=false;
  double reveal_=0;
  ULONGLONG reveal_started_=0;
  std::pair<double,double> TextPoint(LPARAM lp) {
    return {GET_X_LPARAM(lp)/static_cast<double>(std::max(1L,current_.right-current_.left)),GET_Y_LPARAM(lp)/static_cast<double>(std::max(1L,current_.bottom-current_.top))};
  }
  bool HitText(double x,double y) {
    double tx=3.0/std::max(1L,current_.right-current_.left),ty=3.0/std::max(1L,current_.bottom-current_.top);
    for(const auto& g:glyphs_) if(x>=g.x-tx && x<=g.x+g.width+tx && y>=g.y-ty && y<=g.y+g.height+ty) return true;
    return false;
  }
  int Boundary(double x,double y) {
    const TextGlyph* best=nullptr;double distance=1e20;
    for(const auto& g:glyphs_) {
      const double dy=std::max({g.y-y,y-g.y-g.height,0.0}),dx=std::max({g.x-x,x-g.x-g.width,0.0});
      if(dy*1000+dx<distance){distance=dy*1000+dx;best=&g;}
    }
    return best?(x<best->x+best->width/2?best->start:best->end):0;
  }
  void SelectAllText() {anchor_=0;extent_=static_cast<int>(text_.size());reveal_=0;Draw();}
  bool CopyText(bool all=false) {
    if(all && anchor_==extent_) SelectAllText();
    const int start=std::min(anchor_,extent_),end=std::max(anchor_,extent_);
    if(start==end || start<0 || end>static_cast<int>(text_.size())) return false;
    const auto value=text_.substr(start,end-start);
    if(!OpenClipboard(hwnd_)) return true;
    HGLOBAL storage=GlobalAlloc(GMEM_MOVEABLE,(value.size()+1)*sizeof(wchar_t));
    if(storage) {auto ptr=GlobalLock(storage);if(ptr){memcpy(ptr,value.c_str(),(value.size()+1)*sizeof(wchar_t));GlobalUnlock(storage);EmptyClipboard();if(!SetClipboardData(CF_UNICODETEXT,storage))GlobalFree(storage);}else GlobalFree(storage);}
    CloseClipboard();feedback_=2;Draw();SetTimer(hwnd_,2,1000,nullptr);return true;
  }
  RECT Fit(RECT source) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfoW(MonitorFromRect(&source, MONITOR_DEFAULTTONEAREST), &monitor);
    const auto work = monitor.rcWork;
    const double scale = std::min({1.0, (work.right-work.left)*.6/image_->GetWidth(),
        (work.bottom-work.top)*.6/image_->GetHeight()});
    const LONG maxWidth = std::max(1L, static_cast<LONG>(std::min((work.right-work.left)*.6, (work.bottom-work.top)*.6*image_->GetWidth()/image_->GetHeight())));
    const LONG width = std::clamp(static_cast<LONG>(image_->GetWidth()*scale),std::min(static_cast<LONG>(110.0*bar_/34),maxWidth),maxWidth);
    const LONG height = std::max(1L, static_cast<LONG>(image_->GetHeight()*(static_cast<double>(width)/image_->GetWidth())));
    const LONG left = std::clamp(source.left+20, work.left+8, std::max(work.left+8, work.right-width-8));
    const LONG top = std::clamp(source.top-16, work.top+8, std::max(work.top+8, work.bottom-height-8));
    return {left, top, left+width, top+height};
  }
  // Cache a blurred sample of the image beneath the overlaid toolbar. Three
  // separable box passes approximate a Gaussian without a desktop capture.
  void PrepareGlass(int width, int height) {
    if (glass_ && glass_width_ == width && glass_height_ == height) return;
    glass_.reset();
    const int radius = std::max(1, static_cast<int>(bar_/4));
    const int sampleHeight = std::min(height, static_cast<int>(bar_)+radius*3);
    auto blurred = std::make_unique<Gdiplus::Bitmap>(width, sampleHeight, PixelFormat32bppPARGB);
    {
      Gdiplus::Graphics graphics(blurred.get());
      graphics.Clear(Gdiplus::Color(0,0,0,0));
      graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      graphics.DrawImage(image_.get(), Gdiplus::Rect(0,0,width,height));
    }
    Gdiplus::BitmapData data{};
    Gdiplus::Rect rect(0,0,width,sampleHeight);
    if (blurred->LockBits(&rect,Gdiplus::ImageLockModeRead|Gdiplus::ImageLockModeWrite,PixelFormat32bppPARGB,&data) != Gdiplus::Ok) return;
    std::vector<BYTE> input(static_cast<size_t>(width)*sampleHeight*4), output(input.size());
    for (int y=0;y<sampleHeight;y++)
      memcpy(input.data()+static_cast<size_t>(y)*width*4,static_cast<BYTE*>(data.Scan0)+y*data.Stride,static_cast<size_t>(width)*4);
    const int kernel=radius*2+1;
    for (int pass=0;pass<3;pass++) {
      for (int y=0;y<sampleHeight;y++) for (int channel=0;channel<4;channel++) {
        int sum=0;
        auto value=[&](int x){return input[(static_cast<size_t>(y)*width+std::clamp(x,0,width-1))*4+channel];};
        for(int x=-radius;x<=radius;x++) sum+=value(x);
        for(int x=0;x<width;x++) {
          output[(static_cast<size_t>(y)*width+x)*4+channel]=static_cast<BYTE>(sum/kernel);
          sum+=value(x+radius+1)-value(x-radius);
        }
      }
      for (int x=0;x<width;x++) for (int channel=0;channel<4;channel++) {
        int sum=0;
        auto value=[&](int y){return output[(static_cast<size_t>(std::clamp(y,0,sampleHeight-1))*width+x)*4+channel];};
        for(int y=-radius;y<=radius;y++) sum+=value(y);
        for(int y=0;y<sampleHeight;y++) {
          input[(static_cast<size_t>(y)*width+x)*4+channel]=static_cast<BYTE>(sum/kernel);
          sum+=value(y+radius+1)-value(y-radius);
        }
      }
    }
    for (int y=0;y<sampleHeight;y++)
      memcpy(static_cast<BYTE*>(data.Scan0)+y*data.Stride,input.data()+static_cast<size_t>(y)*width*4,static_cast<size_t>(width)*4);
    blurred->UnlockBits(&data);
    glass_=std::move(blurred);glass_width_=width;glass_height_=height;
  }
  void Hover(bool visible) {
    if (visible == hovering_) return;
    hovering_=visible;
    if(visible) {
      TRACKMOUSEEVENT track{sizeof(TRACKMOUSEEVENT),TME_LEAVE,hwnd_,0};
      TrackMouseEvent(&track);
    }
    bar_from_=bar_opacity_;bar_target_=visible?1.0:0.0;
    if (!animate_) {bar_opacity_=bar_target_;Draw();return;}
    bar_started_=GetTickCount64();SetTimer(hwnd_,3,16,nullptr);
  }
  void Draw(BYTE alpha = 255) {
    const int width = current_.right-current_.left, height = current_.bottom-current_.top;
    if (width <= 0 || height <= 0) return;
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
      g.DrawImage(image_.get(), Gdiplus::Rect(0,0,width,height));
      const int first=std::min(anchor_,extent_),last=std::max(anchor_,extent_);
      Gdiplus::SolidBrush textHighlight(Gdiplus::Color(static_cast<BYTE>(first==last?46*reveal_:76),first==last?255:49,first==last?204:185,first==last?102:157));
      for(const auto& glyph:glyphs_) {
        if((first==last && reveal_>0) || (glyph.start<last && glyph.end>first))
          g.FillRectangle(&textHighlight,Gdiplus::RectF(static_cast<float>(glyph.x*width),static_cast<float>(glyph.y*height),static_cast<float>(glyph.width*width),static_cast<float>(glyph.height*height)));
      }
      if (bar_opacity_ > 0) {
      PrepareGlass(width,height);
      const int headerHeight=std::min(height,static_cast<int>(bar_));
      Gdiplus::Bitmap header(width,headerHeight,PixelFormat32bppPARGB);
      {
      Gdiplus::Graphics h(&header);
      h.Clear(Gdiplus::Color(0,0,0,0));
      h.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      if(glass_) h.DrawImage(glass_.get(),0,0);
      Gdiplus::SolidBrush background(Gdiplus::Color(156,24,27,34));
      h.FillRectangle(&background,0,0,width,headerHeight);
      const float uiScale=bar_/34.0f;
      h.ScaleTransform(uiScale,uiScale);
      const int logicalWidth=static_cast<int>(width/uiScale);
      Gdiplus::SolidBrush label(Gdiplus::Color(255,255,255,255));
      Gdiplus::Font font(L"Segoe UI",11,Gdiplus::FontStyleRegular,Gdiplus::UnitPixel);
      const wchar_t* title=feedback_?L"已复制":ocr_status_==0?L"识别文字中…":ocr_status_==1?L"拖选文字 · Ctrl+C":ocr_status_==2?L"未识别到文字":L"文字识别失败";
      if(logicalWidth>=200) h.DrawString(title,-1,&font,Gdiplus::PointF(10,10),&label);
      Gdiplus::Pen pen(Gdiplus::Color(255,255,255,255),1.6f);
      h.DrawRectangle(&pen,logicalWidth-59,12,10,11); h.DrawLine(&pen,logicalWidth-56,8,logicalWidth-46,8);h.DrawLine(&pen,logicalWidth-46,8,logicalWidth-46,18);
      h.DrawLine(&pen,logicalWidth-24,11,logicalWidth-14,21);h.DrawLine(&pen,logicalWidth-14,11,logicalWidth-24,21);
      h.DrawLine(&pen,logicalWidth-96,10,logicalWidth-81,10);h.DrawLine(&pen,logicalWidth-89,10,logicalWidth-89,24);h.DrawLine(&pen,logicalWidth-93,24,logicalWidth-85,24);
      }
      Gdiplus::ColorMatrix matrix={{{1,0,0,0,0},{0,1,0,0,0},{0,0,1,0,0},{0,0,0,static_cast<Gdiplus::REAL>(bar_opacity_),0},{0,0,0,0,1}}};
      Gdiplus::ImageAttributes attributes;attributes.SetColorMatrix(&matrix);
      g.DrawImage(&header,Gdiplus::Rect(0,0,width,headerHeight),0,0,width,headerHeight,Gdiplus::UnitPixel,&attributes);
      }
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
      case WM_DPICHANGED:
        self->bar_=static_cast<LONG>(34.0*HIWORD(wp)/96.0);
        self->glass_.reset();self->Draw();return 0;
      case WM_TIMER:
        if(wp==1) {
          double t=std::min(1.0,(GetTickCount64()-self->started_)/240.0);
          double ease=1-std::pow(1-t,3);
          auto lerp=[ease](LONG a,LONG b){return static_cast<LONG>(a+(b-a)*ease);};
          self->current_={lerp(self->source_.left,self->target_.left),lerp(self->source_.top,self->target_.top),lerp(self->source_.right,self->target_.right),lerp(self->source_.bottom,self->target_.bottom)};
          self->Draw(static_cast<BYTE>(230+25*ease));
          if(t>=1) KillTimer(hwnd,1);
        } else if(wp==2) {KillTimer(hwnd,2);self->feedback_=0;self->Draw();}
        else if(wp==3) {
          double t=std::min(1.0,(GetTickCount64()-self->bar_started_)/(self->bar_target_>0?160.0:100.0));
          double ease=1-std::pow(1-t,3);
          self->bar_opacity_=self->bar_from_+(self->bar_target_-self->bar_from_)*ease;
          self->Draw();
          if(t>=1) KillTimer(hwnd,3);
        }
        else if(wp==4) {
          double elapsed=(GetTickCount64()-self->reveal_started_)/1000.0;
          self->reveal_=self->animate_?std::clamp((1.4-elapsed)/.6,0.0,1.0):(elapsed<1.4?1:0);
          self->Draw();if(elapsed>=1.4)KillTimer(hwnd,4);
        }
        return 0;
      case WM_MOUSEMOVE: {
        self->Hover(true);
        const auto p=self->TextPoint(lp);
        if(self->selecting_text_) {self->extent_=self->Boundary(p.first,p.second);self->Draw();}
        SetCursor(LoadCursorW(nullptr,self->HitText(p.first,p.second)?IDC_IBEAM:IDC_SIZEALL));
        return 0;
      }
      case WM_SETCURSOR: {
        if(LOWORD(lp)==HTCLIENT) {POINT p{};GetCursorPos(&p);ScreenToClient(hwnd,&p);auto point=self->TextPoint(MAKELPARAM(p.x,p.y));SetCursor(LoadCursorW(nullptr,self->HitText(point.first,point.second)?IDC_IBEAM:IDC_SIZEALL));return TRUE;}
        break;
      }
      case WM_MOUSELEAVE: self->Hover(false);return 0;
      case WM_EXITSIZEMOVE: {
        POINT point{};GetCursorPos(&point);RECT rect{};GetWindowRect(hwnd,&rect);
        self->Hover(PtInRect(&rect,point)!=FALSE);return 0;
      }
      case WM_LBUTTONDOWN: {
        KillTimer(hwnd,1);
        RECT rect{};GetWindowRect(hwnd,&rect);self->current_=rect;
        int x=static_cast<int>(GET_X_LPARAM(lp)*34.0/self->bar_),y=GET_Y_LPARAM(lp),width=static_cast<int>((rect.right-rect.left)*34.0/self->bar_);
        if(self->hovering_ && self->bar_opacity_>.05 && y<self->bar_ && x>width-36) {DestroyWindow(hwnd);return 0;}
        if(self->hovering_ && self->bar_opacity_>.05 && y<self->bar_ && x>width-72) {self->Copy();return 0;}
        if(self->hovering_ && self->bar_opacity_>.05 && y<self->bar_ && x>width-108) {self->CopyText(true);return 0;}
        const auto point=self->TextPoint(lp);
        if(GetKeyState(VK_MENU)>=0 && self->HitText(point.first,point.second)) {
          SetForegroundWindow(hwnd);SetFocus(hwnd);SetCapture(hwnd);self->selecting_text_=true;
          self->anchor_=self->extent_=self->Boundary(point.first,point.second);self->reveal_=0;KillTimer(hwnd,4);self->Draw();return 0;
        }
        self->anchor_=self->extent_=0;self->Draw();
        ReleaseCapture();SendMessageW(hwnd,WM_NCLBUTTONDOWN,HTCAPTION,0);return 0;
      }
      case WM_LBUTTONUP:
        if(self->selecting_text_){const auto p=self->TextPoint(lp);self->extent_=self->Boundary(p.first,p.second);self->selecting_text_=false;ReleaseCapture();self->Draw();}return 0;
      case WM_CAPTURECHANGED:self->selecting_text_=false;return 0;
      case WM_MOVE: GetWindowRect(hwnd,&self->current_);return 0;
      case WM_MOUSEWHEEL: {
        KillTimer(hwnd,1);
        RECT rect{};GetWindowRect(hwnd,&rect);
        MONITORINFO monitor{sizeof(MONITORINFO)};GetMonitorInfoW(MonitorFromRect(&rect,MONITOR_DEFAULTTONEAREST),&monitor);
        double ratio=static_cast<double>(self->image_->GetHeight())/self->image_->GetWidth();
        int maxWidth=std::max(1L,std::min(monitor.rcWork.right-monitor.rcWork.left-16,static_cast<LONG>((monitor.rcWork.bottom-monitor.rcWork.top-16)/ratio)));
        int minWidth=std::min(110,maxWidth);
        int width=std::clamp(static_cast<int>((rect.right-rect.left)*(GET_WHEEL_DELTA_WPARAM(wp)>0?1.1:.9)),minWidth,maxWidth);
        int height=std::max(1,static_cast<int>(width*ratio));
        int left=std::clamp(rect.left,monitor.rcWork.left,std::max(monitor.rcWork.left,monitor.rcWork.right-width));
        int top=std::clamp(rect.top,monitor.rcWork.top,std::max(monitor.rcWork.top,monitor.rcWork.bottom-height));
        self->current_={left,top,left+width,top+height};self->Draw();return 0;
      }
      case WM_KEYDOWN:
        if(wp==VK_ESCAPE || wp==VK_DELETE) {DestroyWindow(hwnd);return 0;}
        if(wp=='C' && GetKeyState(VK_CONTROL)<0) {if(!self->CopyText())self->Copy();return 0;}
        if(wp=='A' && GetKeyState(VK_CONTROL)<0) {self->SelectAllText();return 0;}
        break;
      case WM_RBUTTONUP: DestroyWindow(hwnd);return 0;
      case WM_CLOSE: DestroyWindow(hwnd);return 0;
      case WM_NCDESTROY:
        SetWindowLongPtrW(hwnd,GWLP_USERDATA,0);delete self;return DefWindowProcW(hwnd,msg,wp,lp);
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
  }
};
