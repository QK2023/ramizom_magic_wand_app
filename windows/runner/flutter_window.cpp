#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <gdiplus.h>
#include <objidl.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "screen_controls.h"
#include "screen_text.h"

namespace {

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), size);
  return wide;
}

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                       static_cast<int>(wide.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), size, nullptr, nullptr);
  return utf8;
}

std::vector<double> Numbers(const flutter::EncodableMap& map, const char* key) {
  std::vector<double> result;
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end()) return result;
  if (const auto* list = std::get_if<flutter::EncodableList>(&value->second)) {
    for (const auto& item : *list) {
      if (const auto* d = std::get_if<double>(&item)) {
        result.push_back(*d);
      } else if (const auto* i = std::get_if<int32_t>(&item)) {
        result.push_back(*i);
      }
    }
  }
  return result;
}

std::string Text(const flutter::EncodableMap& map, const char* key) {
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end()) return {};
  const auto* text = std::get_if<std::string>(&value->second);
  return text ? *text : std::string();
}

// GDI+ EncoderQuality, declared here to avoid depending on initguid linkage.
const GUID kEncoderQuality = {
    0x1d5be4b5, 0xfa4a, 0x452d, {0x9c, 0xdd, 0x5d, 0xb3, 0x51, 0x05, 0xe7, 0xeb}};

// A capture runs on a worker thread; its result is answered on the window
// thread because Flutter method results must be delivered there.
struct CaptureJob {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  int max_width = 1440;
  bool grid = false;
  // Only a tiny grayscale thumbnail, to tell whether the screen changed.
  bool fingerprint = false;
  std::vector<uint8_t> bytes;
  // With the grid: the text on screen, each line as [x1, y1, x2, y2] in the
  // screenshot's 0..1000 space and its words.
  flutter::EncodableList text;
  // With the grid: the clickable controls, each with "kind" too.
  flutter::EncodableList controls;
  int width = 0;
  int height = 0;
  std::string error;
  bool ok = false;
};

int GetEncoderClsid(const WCHAR* mime_type, CLSID* clsid) {
  UINT count = 0;
  UINT bytes = 0;
  Gdiplus::GetImageEncodersSize(&count, &bytes);
  if (bytes == 0) return -1;
  std::vector<BYTE> storage(bytes);
  auto* encoders =
      reinterpret_cast<Gdiplus::ImageCodecInfo*>(storage.data());
  if (Gdiplus::GetImageEncoders(count, bytes, encoders) != Gdiplus::Ok) {
    return -1;
  }
  for (UINT index = 0; index < count; ++index) {
    if (wcscmp(encoders[index].MimeType, mime_type) == 0) {
      *clsid = encoders[index].Clsid;
      return static_cast<int>(index);
    }
  }
  return -1;
}

bool CaptureVirtualDesktopJpeg(int max_width, bool grid,
                               std::vector<uint8_t>* jpeg,
                              int* output_width, int* output_height,
                              std::string* error) {
  const int source_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int source_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int source_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int source_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (source_width <= 0 || source_height <= 0) {
    *error = "Windows returned an invalid desktop size.";
    return false;
  }

  const double scale =
      source_width > max_width
          ? static_cast<double>(max_width) / static_cast<double>(source_width)
          : 1.0;
  const int width = std::max(1, static_cast<int>(std::round(source_width * scale)));
  const int height = std::max(1, static_cast<int>(std::round(source_height * scale)));

  HDC screen_dc = GetDC(nullptr);
  HDC memory_dc = screen_dc ? CreateCompatibleDC(screen_dc) : nullptr;
  HBITMAP bitmap =
      memory_dc ? CreateCompatibleBitmap(screen_dc, width, height) : nullptr;
  if (!screen_dc || !memory_dc || !bitmap) {
    if (bitmap) DeleteObject(bitmap);
    if (memory_dc) DeleteDC(memory_dc);
    if (screen_dc) ReleaseDC(nullptr, screen_dc);
    *error = "Unable to allocate the Windows screen capture surface.";
    return false;
  }

  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);
  SetStretchBltMode(memory_dc, HALFTONE);
  SetBrushOrgEx(memory_dc, 0, 0, nullptr);
  const BOOL copied = StretchBlt(memory_dc, 0, 0, width, height, screen_dc,
                                 source_x, source_y, source_width, source_height,
                                 SRCCOPY | CAPTUREBLT);
  SelectObject(memory_dc, old_bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
  if (!copied) {
    DeleteObject(bitmap);
    *error = "Windows could not copy the virtual desktop.";
    return false;
  }

  Gdiplus::GdiplusStartupInput startup_input;
  ULONG_PTR gdiplus_token = 0;
  if (Gdiplus::GdiplusStartup(&gdiplus_token, &startup_input, nullptr) !=
      Gdiplus::Ok) {
    DeleteObject(bitmap);
    *error = "GDI+ could not be initialized.";
    return false;
  }

  bool success = false;
  IStream* stream = nullptr;
  CLSID jpeg_encoder{};
  // JPEG keeps screen text legible for vision models at a fraction of the
  // PNG payload and encoding time.
  ULONG quality = 85;
  Gdiplus::EncoderParameters parameters{};
  parameters.Count = 1;
  parameters.Parameter[0].Guid = kEncoderQuality;
  parameters.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
  parameters.Parameter[0].NumberOfValues = 1;
  parameters.Parameter[0].Value = &quality;
  if (GetEncoderClsid(L"image/jpeg", &jpeg_encoder) >= 0 &&
      CreateStreamOnHGlobal(nullptr, TRUE, &stream) == S_OK) {
    Gdiplus::Bitmap image(bitmap, nullptr);
    if (grid) {
      // A faint 0..1000 grid helps the model place annotations precisely.
      Gdiplus::Graphics g(&image);
      g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
      Gdiplus::Pen line(Gdiplus::Color(70, 255, 0, 170), 1);
      Gdiplus::FontFamily family(L"Segoe UI");
      Gdiplus::Font font(&family, 11, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
      Gdiplus::SolidBrush label(Gdiplus::Color(255, 255, 255, 255));
      Gdiplus::SolidBrush chip(Gdiplus::Color(170, 200, 0, 140));
      for (int i = 1; i < 10; ++i) {
        const float x = static_cast<float>(width) * i / 10;
        const float y = static_cast<float>(height) * i / 10;
        g.DrawLine(&line, x, 0.0f, x, static_cast<float>(height));
        g.DrawLine(&line, 0.0f, y, static_cast<float>(width), y);
        const std::wstring text = std::to_wstring(i * 100);
        g.FillRectangle(&chip, x - 12, 0.0f, 24.0f, 14.0f);
        g.DrawString(text.c_str(), -1, &font, Gdiplus::PointF(x - 11, 0), &label);
        g.FillRectangle(&chip, 0.0f, y - 7, 24.0f, 14.0f);
        g.DrawString(text.c_str(), -1, &font, Gdiplus::PointF(1, y - 8), &label);
      }
    }
    if (image.Save(stream, &jpeg_encoder, &parameters) == Gdiplus::Ok) {
      HGLOBAL memory = nullptr;
      if (GetHGlobalFromStream(stream, &memory) == S_OK && memory) {
        const SIZE_T size = GlobalSize(memory);
        const void* data = GlobalLock(memory);
        if (data && size > 0) {
          const auto* first = static_cast<const uint8_t*>(data);
          jpeg->assign(first, first + size);
          GlobalUnlock(memory);
          *output_width = width;
          *output_height = height;
          success = true;
        }
      }
    }
  }
  if (stream) stream->Release();
  Gdiplus::GdiplusShutdown(gdiplus_token);
  DeleteObject(bitmap);
  if (!success) *error = "The captured frame could not be encoded as JPEG.";
  return success;
}

// The whole desktop shrunk to kFingerprintW x kFingerprintH grayscale
// pixels: enough to see a menu open or a dialog appear, a few milliseconds
// to make, and blind to a clock ticking.
constexpr int kFingerprintW = 96;
constexpr int kFingerprintH = 60;

bool DesktopFingerprint(std::vector<uint8_t>* gray) {
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = kFingerprintW;
  info.bmiHeader.biHeight = -kFingerprintH;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  if (memory && dib && bits) {
    HGDIOBJ old = SelectObject(memory, dib);
    SetStretchBltMode(memory, HALFTONE);
    SetBrushOrgEx(memory, 0, 0, nullptr);
    ok = StretchBlt(memory, 0, 0, kFingerprintW, kFingerprintH, screen, x, y,
                    w, h, SRCCOPY) != 0;
    GdiFlush();
    SelectObject(memory, old);
  }
  ReleaseDC(nullptr, screen);
  if (memory) DeleteDC(memory);
  if (ok) {
    const auto* pixels = static_cast<const uint8_t*>(bits);
    gray->resize(kFingerprintW * kFingerprintH);
    for (int i = 0; i < kFingerprintW * kFingerprintH; ++i) {
      (*gray)[i] = static_cast<uint8_t>(
          (pixels[i * 4] * 29 + pixels[i * 4 + 1] * 150 + pixels[i * 4 + 2] * 77) >> 8);
    }
  }
  if (dib) DeleteObject(dib);
  return ok;
}

}  // namespace

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


  audio_ = std::make_unique<AudioEngine>(
      GetHandle(), flutter_controller_->engine()->messenger());
  glow_ = std::make_unique<ScreenGlow>();
  annotator_ = std::make_unique<ScreenAnnotator>(GetHandle());
  annotate_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "ai.ramizom.magic_wand/annotate",
          &flutter::StandardMethodCodec::GetInstance());
  annotate_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "clear") {
          bool board = false;
          if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto value = map->find(flutter::EncodableValue("board"));
            if (value != map->end()) {
              if (const auto* flag = std::get_if<bool>(&value->second)) board = *flag;
            }
          }
          annotator_->Clear(board);
          result->Success();
          return;
        }
        const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() != "draw" || !arguments) {
          result->NotImplemented();
          return;
        }
        ScreenAnnotator::Command command;
        command.type = Text(*arguments, "type");
        command.numbers = Numbers(*arguments, "numbers");
        const auto flat = Numbers(*arguments, "points");
        for (size_t i = 0; i + 1 < flat.size(); i += 2) {
          command.points.emplace_back(flat[i], flat[i + 1]);
        }
        command.text = Widen(Text(*arguments, "text"));
        command.target = Widen(Text(*arguments, "target"));
        {
          const auto exact = arguments->find(flutter::EncodableValue("exact"));
          if (exact != arguments->end()) {
            if (const auto* flag = std::get_if<bool>(&exact->second)) {
              command.exact = *flag;
            }
          }
        }
        command.color = Text(*arguments, "color");
        command.size = Text(*arguments, "size");
        annotator_->Draw(std::move(command));
        result->Success();
      });
  screen_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "ai.ramizom.magic_wand/screen",
          &flutter::StandardMethodCodec::GetInstance());
  screen_channel_->SetMethodCallHandler(
      [this, window = GetHandle()](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setScreenGlow") {
          bool visible = false;
          if (const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto value = arguments->find(flutter::EncodableValue("visible"));
            if (value != arguments->end()) {
              if (const auto* flag = std::get_if<bool>(&value->second)) visible = *flag;
            }
          }
          if (visible) {
            glow_->Show();
          } else {
            glow_->Hide();
          }
          result->Success();
          return;
        }
        if (call.method_name() != "captureScreen" &&
            call.method_name() != "screenFingerprint") {
          result->NotImplemented();
          return;
        }
        auto* job = new CaptureJob();
        job->result = std::move(result);
        job->fingerprint = call.method_name() == "screenFingerprint";
        if (const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto value = arguments->find(flutter::EncodableValue("maxWidth"));
          if (value != arguments->end()) {
            if (const auto* requested = std::get_if<int32_t>(&value->second)) {
              job->max_width = std::clamp(static_cast<int>(*requested), 640, 2560);
            }
          }
          const auto grid = arguments->find(flutter::EncodableValue("grid"));
          if (grid != arguments->end()) {
            if (const auto* flag = std::get_if<bool>(&grid->second)) job->grid = *flag;
          }
        }
        // Capturing and encoding the desktop takes long enough to stall input
        // if it runs on the window thread, so it happens on a worker.
        std::thread([window, job]() {
          const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
          if (job->fingerprint) {
            job->ok = DesktopFingerprint(&job->bytes);
            job->width = kFingerprintW;
            job->height = kFingerprintH;
            if (!job->ok) job->error = "The screen could not be read.";
          } else {
            job->ok = CaptureVirtualDesktopJpeg(job->max_width, job->grid,
                                                &job->bytes,
                                                &job->width, &job->height,
                                                &job->error);
          }
          if (job->ok && job->grid) {
            // Exact positions of what the model may want to mark: the
            // clickable controls (read alongside) and the text.
            std::vector<screen_controls::Control> controls;
            std::thread reader([&controls]() {
              const HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
              controls = screen_controls::ReadControls();
              if (SUCCEEDED(apartment)) CoUninitialize();
            });
            const double vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
            const double vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
            const double vw = std::max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
            const double vh = std::max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
            auto unit = [](double v, double origin, double size) {
              return static_cast<int32_t>(std::lround(
                  std::clamp((v - origin) / size * 1000, 0.0, 1000.0)));
            };
            auto box = [&](const RECT& r) {
              return flutter::EncodableValue(flutter::EncodableList{
                  flutter::EncodableValue(unit(r.left, vx, vw)),
                  flutter::EncodableValue(unit(r.top, vy, vh)),
                  flutter::EncodableValue(unit(r.right, vx, vw)),
                  flutter::EncodableValue(unit(r.bottom, vy, vh))});
            };
            for (const auto& line : screen_text::ReadDesktop()) {
              flutter::EncodableMap item;
              item[flutter::EncodableValue("box")] = box(line.rect);
              item[flutter::EncodableValue("text")] =
                  flutter::EncodableValue(Narrow(line.text));
              job->text.emplace_back(std::move(item));
            }
            reader.join();
            for (const auto& control : controls) {
              flutter::EncodableMap item;
              item[flutter::EncodableValue("box")] = box(control.rect);
              item[flutter::EncodableValue("text")] =
                  flutter::EncodableValue(Narrow(control.name));
              item[flutter::EncodableValue("kind")] =
                  flutter::EncodableValue(std::string(control.kind));
              job->controls.emplace_back(std::move(item));
            }
          }
          if (SUCCEEDED(com)) CoUninitialize();
          if (!PostMessage(window, kCaptureMessage, 0,
                           reinterpret_cast<LPARAM>(job))) {
            delete job;
          }
        }).detach();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Keep the app and its preview out of screen captures (Windows 10 2004+).
  SetWindowDisplayAffinity(GetHandle(), 0x00000011);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  audio_.reset();
  annotate_channel_.reset();
  annotator_.reset();
  screen_channel_.reset();
  glow_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == AudioEngine::kCaptureMessage) {
    if (audio_) audio_->DeliverCapture(wparam, lparam);
    return 0;
  }
  if (message == AudioEngine::kDecodeMessage) {
    AudioEngine::DeliverDecode(lparam);
    return 0;
  }
  if (message == ScreenAnnotator::kBoardSubmitted) {
    // The student's answer on the whiteboard, for the assistant to mark.
    std::unique_ptr<std::vector<uint8_t>> jpeg(
        reinterpret_cast<std::vector<uint8_t>*>(lparam));
    if (annotate_channel_) {
      annotate_channel_->InvokeMethod(
          "submitted",
          std::make_unique<flutter::EncodableValue>(std::move(*jpeg)));
    }
    return 0;
  }
  if (message == kCaptureMessage) {
    std::unique_ptr<CaptureJob> job(reinterpret_cast<CaptureJob*>(lparam));
    if (!job->ok) {
      job->result->Error("capture_failed", job->error);
    } else {
      flutter::EncodableMap response;
      response[flutter::EncodableValue("bytes")] = flutter::EncodableValue(std::move(job->bytes));
      response[flutter::EncodableValue("width")] = flutter::EncodableValue(job->width);
      response[flutter::EncodableValue("height")] = flutter::EncodableValue(job->height);
      response[flutter::EncodableValue("text")] = flutter::EncodableValue(std::move(job->text));
      response[flutter::EncodableValue("controls")] = flutter::EncodableValue(std::move(job->controls));
      job->result->Success(flutter::EncodableValue(response));
    }
    return 0;
  }
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
