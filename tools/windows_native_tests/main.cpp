#include <windows.h>
#include <gdiplus.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include "ocr_service.h"
#include "pinned_image_window.h"

void Check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
std::vector<uint8_t> Fixture() {
  Gdiplus::Bitmap image(1100, 180, PixelFormat32bppARGB);
  Gdiplus::Graphics graphics(&image);
  graphics.Clear(Gdiplus::Color(255,255,255,255));
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  Gdiplus::Font font(L"Segoe UI", 54, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::SolidBrush brush(Gdiplus::Color(255,0,0,0));
  graphics.DrawString(L"SCREENCLIP OCR 2026",-1,&font,Gdiplus::PointF(25,45),&brush);
  UINT count=0,size=0;Gdiplus::GetImageEncodersSize(&count,&size);
  std::vector<BYTE> encoders(size);auto list=reinterpret_cast<Gdiplus::ImageCodecInfo*>(encoders.data());
  Gdiplus::GetImageEncoders(count,size,list);CLSID png{};bool found=false;
  for(UINT i=0;i<count;++i) if(wcscmp(list[i].MimeType,L"image/png")==0){png=list[i].Clsid;found=true;break;}
  Check(found,"PNG encoder missing");
  IStream* stream=nullptr;Check(SUCCEEDED(CreateStreamOnHGlobal(nullptr,TRUE,&stream)),"Cannot create PNG stream");
  Check(image.Save(stream,&png,nullptr)==Gdiplus::Ok,"Cannot encode fixture");
  STATSTG stat{};stream->Stat(&stat,STATFLAG_NONAME);HGLOBAL memory=nullptr;GetHGlobalFromStream(stream,&memory);
  auto data=static_cast<uint8_t*>(GlobalLock(memory));Check(data!=nullptr,"Cannot read fixture");
  std::vector<uint8_t> bytes(data,data+stat.cbSize.QuadPart);GlobalUnlock(memory);stream->Release();return bytes;
}
std::wstring ClipboardText(HWND hwnd) {
  bool opened=false;
  for(int attempt=0;attempt<25 && !opened;++attempt) {opened=OpenClipboard(hwnd)!=FALSE;if(!opened)Sleep(20);}
  Check(opened,"Cannot open clipboard");
  auto handle=GetClipboardData(CF_UNICODETEXT);
  auto ptr=handle?static_cast<const wchar_t*>(GlobalLock(handle)):nullptr;
  std::wstring text=ptr?ptr:L"";if(ptr)GlobalUnlock(handle);CloseClipboard();return text;
}
int main() {
  CoInitializeEx(nullptr,COINIT_MULTITHREADED);
  Gdiplus::GdiplusStartupInput input;ULONG_PTR token=0;Gdiplus::GdiplusStartup(&token,&input,nullptr);
  HWND pin=nullptr;
  try {
    auto bytes=Fixture();
    Check(desktop_vision::IsOcrSupported(),"No Windows OCR language component is installed");
    auto result=desktop_vision::RecognizeImageBytes(bytes,{"en-US"});
    Check(result.ok,result.error.c_str());
    auto text=std::get<std::string>(result.value.at(flutter::EncodableValue("text")));
    std::cout<<"OCR: "<<text<<std::endl;
    Check(text.find("SCREENCLIP")!=std::string::npos && text.find("2026")!=std::string::npos,"Native OCR did not recognize fixture text");
    Check(!std::get<flutter::EncodableList>(result.value.at(flutter::EncodableValue("lines"))).empty(),"OCR word geometry missing");
    std::cout<<"PASS: Windows OCR recognizes in-memory PNG and returns text geometry"<<std::endl;
    pin=PinnedImageWindow::Show(bytes,{100,100,900,300},false);Check(pin!=nullptr,"Cannot create pin");
    RECT pinFrame{};GetWindowRect(pin,&pinFrame);Check(pinFrame.right-pinFrame.left>1 && pinFrame.bottom-pinFrame.top>1,"Reduced-motion pin has an invalid frame");
    PinnedImageWindow::SetOcrId(pin,"session-pin");
    PinnedImageWindow::SetOcr(pin,"session-pin",L"SCREENCLIP OCR 2026",{{0,10,0,.02,.25,.4,.5},{11,14,0,.45,.25,.15,.5},{15,19,0,.65,.25,.3,.5}},1);
    // Stale asynchronous OCR must not overwrite a different pin session.
    PinnedImageWindow::SetOcr(pin,"stale-pin",L"WRONG",{},1);
    BYTE previous[256]{};GetKeyboardState(previous);BYTE keys[256]{};memcpy(keys,previous,256);keys[VK_CONTROL]=0x80;SetKeyboardState(keys);
    SendMessageW(pin,WM_KEYDOWN,'A',0);SendMessageW(pin,WM_KEYDOWN,'C',0);SetKeyboardState(previous);
    Check(ClipboardText(pin)==L"SCREENCLIP OCR 2026","Pin select-all/copy-text or stale OCR protection failed");
    std::cout<<"PASS: native pin OCR selection/copy and stale-result protection"<<std::endl;
    SendMessageW(pin,WM_KEYDOWN,VK_ESCAPE,0);Check(!IsWindow(pin),"Pin did not close");pin=nullptr;
  } catch(const std::exception& error) {
    if(pin && IsWindow(pin)) DestroyWindow(pin);
    std::cerr<<"FAIL: "<<error.what()<<std::endl;Gdiplus::GdiplusShutdown(token);CoUninitialize();return 1;
  }
  Gdiplus::GdiplusShutdown(token);CoUninitialize();return 0;
}
