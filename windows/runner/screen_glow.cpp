#include "screen_glow.h"

#include <algorithm>
#include <chrono>
#include <cmath>

namespace {

constexpr wchar_t kClassName[] = L"MagicWandScreenGlow";
constexpr double kPi = 3.14159265358979323846;
// WDA_EXCLUDEFROMCAPTURE (Windows 10 2004+): keep the glow out of captures.
constexpr DWORD kExcludeFromCapture = 0x00000011;

// The app icon's palette (deep blue, sky, cyan, mint, warm yellow) with a
// coral red so the light reads as alive rather than cold.
constexpr GlowRgb kPalette[] = {
    {47, 107, 255}, {34, 184, 240}, {62, 230, 180},
    {255, 207, 64}, {255, 77, 94},  {255, 92, 160}, {124, 108, 255},
};
constexpr int kPaletteSize = sizeof(kPalette) / sizeof(kPalette[0]);

GlowRgb Sample(double t) {
  t -= std::floor(t);
  const double scaled = t * kPaletteSize;
  const int index = static_cast<int>(scaled) % kPaletteSize;
  const GlowRgb& a = kPalette[index];
  const GlowRgb& b = kPalette[(index + 1) % kPaletteSize];
  double f = scaled - std::floor(scaled);
  f = f * f * (3 - 2 * f);
  return {a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f};
}

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  MONITORINFO info{sizeof(info)};
  if (GetMonitorInfo(monitor, &info)) {
    reinterpret_cast<std::vector<RECT>*>(data)->push_back(info.rcMonitor);
  }
  return TRUE;
}

}  // namespace

ScreenGlow::ScreenGlow() {
  wake_ = CreateEvent(nullptr, FALSE, FALSE, nullptr);
}

ScreenGlow::~ScreenGlow() {
  quit_ = true;
  if (wake_) SetEvent(wake_);
  if (thread_.joinable()) thread_.join();
  if (wake_) CloseHandle(wake_);
}

void ScreenGlow::Show() {
  visible_ = true;
  if (!thread_.joinable()) thread_ = std::thread(&ScreenGlow::Run, this);
  SetEvent(wake_);
}

void ScreenGlow::Hide() {
  visible_ = false;
  if (wake_) SetEvent(wake_);
}

void ScreenGlow::Run() {
  WNDCLASS window_class{};
  window_class.lpfnWndProc = DefWindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kClassName;
  RegisterClass(&window_class);

  auto last = std::chrono::steady_clock::now();
  while (!quit_) {
    const bool animating = visible_ || intensity_ > 0;
    MsgWaitForMultipleObjects(1, &wake_, FALSE, animating ? 16 : INFINITE,
                              QS_ALLINPUT);
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    if (quit_) break;

    const auto now = std::chrono::steady_clock::now();
    const double dt = std::min(
        0.05, std::chrono::duration<double>(now - last).count());
    last = now;

    if (visible_ && strips_.empty()) CreateStrips();
    // Ease in over ~0.6 s and out over ~0.4 s.
    intensity_ = visible_ ? std::min(1.0, intensity_ + dt / 0.6)
                          : std::max(0.0, intensity_ - dt / 0.4);
    if (!visible_ && intensity_ <= 0) {
      DestroyStrips();
      continue;
    }
    phase_ += dt * 0.08;
    wave_ += dt * 0.5;
    ++frame_;
    for (auto& strip : strips_) Render(strip);
  }
  DestroyStrips();
  UnregisterClass(kClassName, GetModuleHandle(nullptr));
}

void ScreenGlow::CreateStrips() {
  std::vector<RECT> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&monitors));
  HDC screen = GetDC(nullptr);
  for (const RECT& monitor : monitors) {
    const int width = monitor.right - monitor.left;
    const int height = monitor.bottom - monitor.top;
    // Scales with the display: ~40 px at 1440p, ~60 px at 4K.
    const int thickness = std::clamp(height / 36, 24, 72);
    const RECT bounds[] = {
        {monitor.left, monitor.top, monitor.right, monitor.top + thickness},
        {monitor.right - thickness, monitor.top + thickness, monitor.right,
         monitor.bottom - thickness},
        {monitor.left, monitor.bottom - thickness, monitor.right,
         monitor.bottom},
        {monitor.left, monitor.top + thickness, monitor.left + thickness,
         monitor.bottom - thickness},
    };
    if (width <= 2 * thickness || height <= 2 * thickness) continue;
    for (int side = 0; side < 4; ++side) {
      Strip strip;
      strip.edge = static_cast<Edge>(side);
      strip.monitor = monitor;
      strip.bounds = bounds[side];
      strip.thickness = thickness;
      const int w = strip.bounds.right - strip.bounds.left;
      const int h = strip.bounds.bottom - strip.bounds.top;
      strip.window = CreateWindowEx(
          WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST |
              WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
          kClassName, L"", WS_POPUP, strip.bounds.left, strip.bounds.top, w,
          h, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
      if (!strip.window) continue;
      SetWindowDisplayAffinity(strip.window, kExcludeFromCapture);
      BITMAPINFO info{};
      info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      info.bmiHeader.biWidth = w;
      info.bmiHeader.biHeight = -h;  // Top-down rows.
      info.bmiHeader.biPlanes = 1;
      info.bmiHeader.biBitCount = 32;
      info.bmiHeader.biCompression = BI_RGB;
      void* bits = nullptr;
      strip.dc = CreateCompatibleDC(screen);
      strip.bitmap =
          CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
      if (!strip.dc || !strip.bitmap) {
        if (strip.bitmap) DeleteObject(strip.bitmap);
        if (strip.dc) DeleteDC(strip.dc);
        DestroyWindow(strip.window);
        continue;
      }
      strip.pixels = static_cast<uint32_t*>(bits);
      strip.previous = SelectObject(strip.dc, strip.bitmap);
      strips_.push_back(strip);
      ShowWindow(strip.window, SW_SHOWNOACTIVATE);
    }
  }
  ReleaseDC(nullptr, screen);
}

void ScreenGlow::DestroyStrips() {
  for (auto& strip : strips_) {
    SelectObject(strip.dc, strip.previous);
    DeleteObject(strip.bitmap);
    DeleteDC(strip.dc);
    DestroyWindow(strip.window);
  }
  strips_.clear();
}

void ScreenGlow::Render(Strip& strip) {
  const int w = strip.bounds.right - strip.bounds.left;
  const int h = strip.bounds.bottom - strip.bounds.top;
  const int mw = strip.monitor.right - strip.monitor.left;
  const int mh = strip.monitor.bottom - strip.monitor.top;
  const int perimeter = 2 * (mw + mh);
  // The glow grows inward as it fades in.
  const double reach = strip.thickness * (0.55 + 0.45 * intensity_);

  // Colour and depth along the whole perimeter, so where two edges meet at a
  // corner both read the same continuous values and the light never breaks.
  if (static_cast<int>(colors_.size()) != perimeter) {
    colors_.resize(perimeter);
    extents_.resize(perimeter);
  }
  if (frame_key_ != frame_ || frame_monitor_.left != strip.monitor.left ||
      frame_monitor_.top != strip.monitor.top || frame_size_ != perimeter) {
    for (int along = 0; along < perimeter; ++along) {
      const double p = static_cast<double>(along) / perimeter;
      colors_[along] = Sample(p * 2 + phase_);
      // A slow travelling swell makes the light breathe along the edge.
      const double swell = 0.5 + 0.5 * std::sin(2 * kPi * (p * 3 - wave_));
      extents_[along] = reach * (0.55 + 0.45 * swell);
    }
    frame_key_ = frame_;
    frame_monitor_ = strip.monitor;
    frame_size_ = perimeter;
  }

  const int thickness = strip.thickness;
  for (int y = 0; y < h; ++y) {
    const int my = strip.bounds.top - strip.monitor.top + y;
    for (int x = 0; x < w; ++x) {
      const int mx = strip.bounds.left - strip.monitor.left + x;
      // Light from every edge within reach: top, right, bottom, left.
      const int distances[4] = {my, mw - 1 - mx, mh - 1 - my, mx};
      const int positions[4] = {mx, mw + my, mw + mh + (mw - 1 - mx),
                                2 * mw + mh + (mh - 1 - my)};
      double transparency = 1, r = 0, g = 0, b = 0, weight = 0;
      for (int edge = 0; edge < 4; ++edge) {
        const int distance = distances[edge];
        if (distance >= thickness) continue;
        const int along = std::clamp(positions[edge], 0, perimeter - 1);
        const double extent = extents_[along];
        double alpha = 0;
        if (distance < extent) {
          const double u = 1 - distance / extent;
          alpha = u * u * 0.9;
        }
        if (distance < 2) alpha = std::max(alpha, 0.95);
        if (alpha <= 0) continue;
        transparency *= 1 - alpha;
        const GlowRgb& c = colors_[along];
        r += c.r * alpha;
        g += c.g * alpha;
        b += c.b * alpha;
        weight += alpha;
      }
      const double alpha = (1 - transparency) * intensity_;
      uint32_t pixel = 0;
      if (weight > 0 && alpha > 0) {
        const double scale = alpha / weight;
        pixel = (static_cast<uint32_t>(alpha * 255 + 0.5) << 24) |
                (static_cast<uint32_t>(r * scale + 0.5) << 16) |
                (static_cast<uint32_t>(g * scale + 0.5) << 8) |
                static_cast<uint32_t>(b * scale + 0.5);
      }
      strip.pixels[y * w + x] = pixel;
    }
  }

  POINT position{strip.bounds.left, strip.bounds.top};
  SIZE size{w, h};
  POINT origin{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(strip.window, nullptr, &position, &size, strip.dc,
                      &origin, 0, &blend, ULW_ALPHA);
}
