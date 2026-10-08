#include "screen_annotator.h"

#include "screen_text.h"

#include <gdiplus.h>

#include <algorithm>
#include <optional>
#include <tuple>
#include <chrono>
#include <cmath>
#include <map>

namespace {

constexpr wchar_t kMarkClass[] = L"MagicWandAnnotation";
constexpr wchar_t kBoardClass[] = L"MagicWandWhiteboard";
// WDA_EXCLUDEFROMCAPTURE: the model keeps seeing the screen, not its marks.
constexpr DWORD kExcludeFromCapture = 0x00000011;
constexpr double kPi = 3.14159265358979323846;
constexpr double kFadeSeconds = 0.35;
// A breath between one mark and the next.
constexpr double kGapSeconds = 0.12;

double Now() {
  using namespace std::chrono;
  return duration<double>(steady_clock::now().time_since_epoch()).count();
}

Gdiplus::Color Ink(const std::string& name, const std::string& fallback,
                   BYTE alpha) {
  const std::string& c = name.empty() ? fallback : name;
  if (c == "blue") return Gdiplus::Color(alpha, 30, 99, 245);
  if (c == "green") return Gdiplus::Color(alpha, 30, 150, 82);
  if (c == "yellow") return Gdiplus::Color(alpha, 255, 196, 0);
  if (c == "white") return Gdiplus::Color(alpha, 248, 248, 244);
  if (c == "black") return Gdiplus::Color(alpha, 33, 37, 48);
  if (c == "orange") return Gdiplus::Color(alpha, 240, 120, 0);
  if (c == "purple") return Gdiplus::Color(alpha, 126, 87, 194);
  return Gdiplus::Color(alpha, 222, 52, 48);  // teacher's red
}

Gdiplus::Color Scaled(Gdiplus::Color color, double factor) {
  return Gdiplus::Color(
      static_cast<BYTE>(std::clamp(color.GetA() * factor, 0.0, 255.0)),
      color.GetR(), color.GetG(), color.GetB());
}

// A gentle deterministic waver so strokes look drawn by hand.
double Wobble(double t, double seed) {
  return std::sin(t * 11.0 + seed) * 0.6 + std::sin(t * 27.0 + seed * 1.7) * 0.4;
}

double EaseOut(double t) {
  return 1 - std::pow(1 - std::clamp(t, 0.0, 1.0), 2.2);
}

// Small deterministic randomness for handwriting irregularities.
struct Random {
  explicit Random(uint32_t seed) : state(seed * 2654435761u + 0x9E3779B9u) {}
  double Next() {
    state = state * 1664525u + 1013904223u;
    return (state >> 8) / 16777216.0;
  }
  double Range(double low, double high) { return low + (high - low) * Next(); }
  uint32_t state;
};

bool IsCjk(wchar_t c) {
  return (c >= 0x3400 && c <= 0x9FFF) || (c >= 0x3000 && c <= 0x303F) ||
         (c >= 0xFF00 && c <= 0xFFEF) || (c >= 0xF900 && c <= 0xFAFF);
}

bool IsAscii(wchar_t c) { return c >= 0x21 && c <= 0x7E; }

std::wstring ExeDirectory() {
  wchar_t path[MAX_PATH];
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring result(path);
  return result.substr(0, result.find_last_of(L"\\/"));
}

void AddRoundedRect(Gdiplus::GraphicsPath& shape, const Gdiplus::RectF& r,
                    float radius) {
  const float d = std::min({radius * 2, r.Width, r.Height});
  if (d <= 0) return;
  shape.AddArc(r.X, r.Y, d, d, 180, 90);
  shape.AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
  shape.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
  shape.AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
  shape.CloseFigure();
}

// Stacking order on screen: highlights lie under everything, notes on top.
int RankOf(const std::string& type) {
  if (type == "highlight") return 0;
  if (type == "arrow") return 2;
  if (type == "text") return 3;
  return 1;  // circle, box, underline, line, path
}

struct Surface {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ previous = nullptr;
  void* bits = nullptr;
};

bool CreateSurface(int w, int h, Surface* surface) {
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = w;
  info.bmiHeader.biHeight = -h;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr);
  surface->dc = CreateCompatibleDC(screen);
  surface->bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
                                     &surface->bits, nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (!surface->dc || !surface->bitmap) return false;
  surface->previous = SelectObject(surface->dc, surface->bitmap);
  return true;
}

void DestroySurface(Surface* surface) {
  if (surface->dc && surface->previous) {
    SelectObject(surface->dc, surface->previous);
  }
  if (surface->bitmap) DeleteObject(surface->bitmap);
  if (surface->dc) DeleteDC(surface->dc);
  *surface = Surface{};
}

// Shows a surface in a layered window; a null [position] keeps the window
// where it is (the user may have dragged it).
void Present(HWND window, const Surface& surface, int w, int h,
             POINT* position) {
  SIZE size{w, h};
  POINT origin{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(window, nullptr, position, &size, surface.dc, &origin, 0,
                      &blend, ULW_ALPHA);
}

// Where an arrow from (x1, y1) toward the middle of [rect] meets the rect
// grown by [gap]; the tip stays put when the arrow starts inside it.
void AimAt(const RECT& rect, double x1, double y1, double gap, double* x2,
           double* y2) {
  const double left = rect.left - gap, right = rect.right + gap;
  const double top = rect.top - gap, bottom = rect.bottom + gap;
  if (x1 >= left && x1 <= right && y1 >= top && y1 <= bottom) return;
  const double cx = (rect.left + rect.right) / 2.0;
  const double cy = (rect.top + rect.bottom) / 2.0;
  const double dx = cx - x1, dy = cy - y1;
  // The first time the line from the tail enters the grown rect.
  double enter = 0, leave = 1;
  for (const auto& [d, from, low, high] :
       {std::tuple{dx, x1, left, right}, std::tuple{dy, y1, top, bottom}}) {
    if (std::abs(d) < 1e-9) continue;
    const double a = (low - from) / d, b = (high - from) / d;
    enter = std::max(enter, std::min(a, b));
    leave = std::min(leave, std::max(a, b));
  }
  if (enter > leave) return;
  *x2 = x1 + dx * enter;
  *y2 = y1 + dy * enter;
}

// GDI+ EncoderQuality, declared here to avoid depending on initguid linkage.
const GUID kJpegQuality = {
    0x1d5be4b5, 0xfa4a, 0x452d, {0x9c, 0xdd, 0x5d, 0xb3, 0x51, 0x05, 0xe7, 0xeb}};

bool EncodeJpeg(Gdiplus::Bitmap& image, std::vector<uint8_t>* jpeg) {
  UINT count = 0, bytes = 0;
  Gdiplus::GetImageEncodersSize(&count, &bytes);
  if (bytes == 0) return false;
  std::vector<BYTE> storage(bytes);
  auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(storage.data());
  if (Gdiplus::GetImageEncoders(count, bytes, encoders) != Gdiplus::Ok) {
    return false;
  }
  const CLSID* clsid = nullptr;
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(encoders[i].MimeType, L"image/jpeg") == 0) {
      clsid = &encoders[i].Clsid;
    }
  }
  if (!clsid) return false;
  ULONG quality = 90;
  Gdiplus::EncoderParameters parameters{};
  parameters.Count = 1;
  parameters.Parameter[0].Guid = kJpegQuality;
  parameters.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
  parameters.Parameter[0].NumberOfValues = 1;
  parameters.Parameter[0].Value = &quality;
  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK) return false;
  bool ok = false;
  if (image.Save(stream, clsid, &parameters) == Gdiplus::Ok) {
    HGLOBAL memory = nullptr;
    if (GetHGlobalFromStream(stream, &memory) == S_OK && memory) {
      const SIZE_T size = GlobalSize(memory);
      const auto* data = static_cast<const uint8_t*>(GlobalLock(memory));
      if (data && size > 0) {
        jpeg->assign(data, data + size);
        ok = true;
      }
      GlobalUnlock(memory);
    }
  }
  stream->Release();
  return ok;
}

}  // namespace

// Handwriting fonts bundled with the app, plus installed fallbacks, chosen
// per character so every symbol has a glyph.
struct ScreenAnnotator::Fonts {
  Fonts() {
    const std::wstring dir =
        ExeDirectory() + L"\\data\\flutter_assets\\assets\\fonts\\";
    for (const wchar_t* name :
         {L"LongCang-Regular.ttf", L"Caveat.ttf", L"Kalam-Regular.ttf"}) {
      const std::wstring file = dir + name;
      if (GetFileAttributesW(file.c_str()) == INVALID_FILE_ATTRIBUTES) continue;
      collection.AddFontFile(file.c_str());
      AddFontResourceExW(file.c_str(), FR_PRIVATE, nullptr);
      files.push_back(file);
    }
    dc = CreateCompatibleDC(nullptr);
  }

  ~Fonts() {
    for (auto& entry : gdi) DeleteObject(entry.second);
    if (dc) DeleteDC(dc);
    for (const auto& file : files) {
      RemoveFontResourceExW(file.c_str(), FR_PRIVATE, nullptr);
    }
  }

  Gdiplus::FontFamily* Family(const std::wstring& name) {
    const auto found = families.find(name);
    if (found != families.end()) return found->second.get();
    auto family =
        std::make_unique<Gdiplus::FontFamily>(name.c_str(), &collection);
    if (!family->IsAvailable()) {
      family = std::make_unique<Gdiplus::FontFamily>(name.c_str());
    }
    if (!family->IsAvailable()) family.reset();
    Gdiplus::FontFamily* result = family.get();
    families[name] = std::move(family);
    return result;
  }

  bool HasGlyph(const std::wstring& name, wchar_t c) {
    HFONT& font = gdi[name];
    if (!font) {
      font = CreateFontW(-48, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0,
                         0, ANTIALIASED_QUALITY, 0, name.c_str());
    }
    const HGDIOBJ old = SelectObject(dc, font);
    WORD index = 0xFFFF;
    GetGlyphIndicesW(dc, &c, 1, &index, GGI_MARK_NONEXISTING_GLYPHS);
    SelectObject(dc, old);
    return index != 0xFFFF;
  }

  // The most hand-written font that actually has [c].
  Gdiplus::FontFamily* For(wchar_t c) {
    static const wchar_t* chinese[] = {L"Long Cang", L"STXingkai", L"KaiTi",
                                       L"Microsoft YaHei"};
    static const wchar_t* latin[] = {L"Caveat", L"Kalam", L"Ink Free",
                                     L"Segoe Print"};
    static const wchar_t* symbols[] = {L"Caveat", L"Kalam", L"Segoe Print",
                                       L"Segoe UI Symbol", L"Cambria Math",
                                       L"Microsoft YaHei"};
    const auto try_list = [&](auto& list) -> Gdiplus::FontFamily* {
      for (const wchar_t* name : list) {
        Gdiplus::FontFamily* family = Family(name);
        if (family && HasGlyph(name, c)) return family;
      }
      return nullptr;
    };
    Gdiplus::FontFamily* family = IsCjk(c)     ? try_list(chinese)
                                  : IsAscii(c) ? try_list(latin)
                                               : try_list(symbols);
    return family ? family : Family(L"Segoe UI");
  }

  Gdiplus::PrivateFontCollection collection;
  std::vector<std::wstring> files;
  HDC dc = nullptr;
  std::map<std::wstring, HFONT> gdi;
  std::map<std::wstring, std::unique_ptr<Gdiplus::FontFamily>> families;
};

struct ScreenAnnotator::Mark {
  struct Glyph {
    std::unique_ptr<Gdiplus::GraphicsPath> path;
    Gdiplus::RectF bounds;
    float weight = 0;   // extra ink for fine-stroked handwriting
    double begin = 0;   // seconds after the mark starts
    double length = 0;  // seconds to write it
  };
  std::string type;
  int rank = 1;
  bool halo = true;                     // light outline for busy screens
  std::vector<Gdiplus::PointF> stroke;  // drawing space
  std::vector<Gdiplus::PointF> head;    // arrowhead, drawing space
  std::vector<Glyph> glyphs;            // handwritten notes, drawing space
  Gdiplus::RectF rect;                  // extent, drawing space
  Gdiplus::Color color;
  float width = 4;
  RECT bounds{};  // screen marks: their window on screen
  double start = 0;
  double duration = 0.6;
  double fade = -1;
  bool settled = false;
  HWND window = nullptr;
  Surface surface;

  // Moves everything drawn by (-dx, -dy) into a window's own space.
  void Shift(float dx, float dy) {
    for (auto& p : stroke) p = Gdiplus::PointF(p.X - dx, p.Y - dy);
    for (auto& p : head) p = Gdiplus::PointF(p.X - dx, p.Y - dy);
    for (auto& glyph : glyphs) {
      Gdiplus::Matrix shift;
      shift.Translate(-dx, -dy);
      glyph.path->Transform(&shift);
      glyph.bounds.X -= dx;
      glyph.bounds.Y -= dy;
    }
    rect.X -= dx;
    rect.Y -= dy;
  }
};

struct ScreenAnnotator::Board {
  HWND window = nullptr;
  Surface surface;
  int width = 0, height = 0;  // window size
  float margin = 0;           // room for the shadow
  float header = 0;           // title bar height
  Gdiplus::RectF panel;       // the board itself, window space
  Gdiplus::RectF canvas;      // where drawings go, window space
  Gdiplus::RectF close;       // close button, window space
  std::wstring title;
  std::vector<std::unique_ptr<Mark>> marks;
  double start = 0;
  double fade = -1;
  double close_at = -1;  // closes once queued drawings have finished
  // The assistant has moved back to the screen: the board stays for the
  // user to read, but takes no more marks.
  bool detached = false;
  bool dirty = true;
  // Practice: the student writes an answer by hand and hands it in.
  bool answering = false;
  std::wstring submit_label, clear_label;
  Gdiplus::RectF submit, clear;  // buttons in the title bar, window space
  std::vector<std::vector<Gdiplus::PointF>> ink;  // strokes, window space
  bool inking = false;
};

ScreenAnnotator::ScreenAnnotator(HWND app) : app_(app) {
  wake_ = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  thread_ = std::thread(&ScreenAnnotator::Run, this);
}

ScreenAnnotator::~ScreenAnnotator() {
  quit_ = true;
  if (wake_) SetEvent(wake_);
  if (thread_.joinable()) thread_.join();
  if (wake_) CloseHandle(wake_);
}

void ScreenAnnotator::Draw(Command command) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.push_back(std::move(command));
  }
  SetEvent(wake_);
}

void ScreenAnnotator::Clear(bool board) {
  Command clear;
  clear.type = "clear";
  if (board) clear.text = L"board";
  Draw(std::move(clear));
}

void ScreenAnnotator::Run() {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_, &input, nullptr);
  WNDCLASS marks{};
  marks.lpfnWndProc = DefWindowProc;
  marks.hInstance = GetModuleHandle(nullptr);
  marks.lpszClassName = kMarkClass;
  RegisterClass(&marks);
  WNDCLASS board{};
  board.lpfnWndProc = BoardProc;
  board.hInstance = GetModuleHandle(nullptr);
  board.hCursor = LoadCursor(nullptr, IDC_ARROW);
  board.lpszClassName = kBoardClass;
  RegisterClass(&board);

  while (!quit_) {
    bool animating = board_ && (board_->dirty || board_->fade >= 0 ||
                                board_->close_at >= 0);
    for (const auto& mark : marks_) {
      animating = animating || !mark->settled || mark->fade >= 0;
    }
    MsgWaitForMultipleObjects(1, &wake_, FALSE, animating ? 16 : INFINITE,
                              QS_ALLINPUT);
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    if (quit_) break;
    const double now = Now();
    std::deque<Command> commands;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      commands.swap(pending_);
    }
    for (const auto& command : commands) Apply(command, now);
    for (auto& mark : marks_) {
      if (!mark->settled || mark->fade >= 0) Render(*mark, now);
    }
    if (board_) {
      if (board_->close_at >= 0 && now >= board_->close_at &&
          board_->fade < 0) {
        board_->fade = now;
      }
      if (board_->dirty || board_->fade >= 0) RenderBoard(now);
      if (board_->fade >= 0 && now - board_->fade >= kFadeSeconds) {
        DestroyBoard();
      }
    }
    marks_.erase(std::remove_if(marks_.begin(), marks_.end(),
                                [&](std::unique_ptr<Mark>& mark) {
                                  if (mark->fade < 0 ||
                                      now - mark->fade < kFadeSeconds) {
                                    return false;
                                  }
                                  Destroy(*mark);
                                  return true;
                                }),
                 marks_.end());
  }
  for (auto& mark : marks_) Destroy(*mark);
  marks_.clear();
  DestroyBoard();
  fonts_.reset();
  UnregisterClass(kMarkClass, GetModuleHandle(nullptr));
  UnregisterClass(kBoardClass, GetModuleHandle(nullptr));
  Gdiplus::GdiplusShutdown(gdiplus_);
}

void ScreenAnnotator::Apply(const Command& command, double now) {
  const std::string& type = command.type;
  if (type == "clear") {
    for (auto& mark : marks_) {
      if (mark->fade < 0) mark->fade = now;
    }
    // The whiteboard is the user's to close; only a full clear takes it.
    if (board_ && board_->fade < 0 && command.text == L"board") {
      board_->fade = now;
      board_->dirty = true;
    }
    queue_end_ = now;
    // Notes already drawn keep their outlines; the fonts can go until the
    // next one.
    fonts_.reset();
    return;
  }
  if (type == "whiteboard") {
    OpenBoard(command.text, std::max(now, queue_end_));
    if (board_) queue_end_ = board_->start + 0.3;
    return;
  }
  if (type == "exercise") {
    StartExercise(command.text, std::max(now, queue_end_));
    return;
  }
  if (type == "close_whiteboard") {
    // After whatever is still being written on it, plus a moment to read.
    // Not closed under the user's eyes: it stays until they close it.
    if (board_) board_->detached = true;
    return;
  }
  const bool on_board =
      board_ && board_->fade < 0 && board_->close_at < 0 && !board_->detached;
  auto mark = Build(command, on_board);
  if (!mark) return;

  // One mark after another, at a hand's pace.
  mark->start = std::max(now, queue_end_ + kGapSeconds);
  queue_end_ = mark->start + mark->duration;

  if (on_board) {
    board_->marks.push_back(std::move(mark));
    // Shapes above highlights on the board too.
    std::stable_sort(
        board_->marks.begin(), board_->marks.end(),
        [](const auto& a, const auto& b) { return a->rank < b->rank; });
    board_->dirty = true;
    return;
  }

  const int w = mark->bounds.right - mark->bounds.left;
  const int h = mark->bounds.bottom - mark->bounds.top;
  if (w <= 0 || h <= 0) return;
  mark->window = CreateWindowEx(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kMarkClass, L"", WS_POPUP, mark->bounds.left, mark->bounds.top, w, h,
      nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!mark->window) return;
  SetWindowDisplayAffinity(mark->window, kExcludeFromCapture);
  if (!CreateSurface(w, h, &mark->surface)) {
    Destroy(*mark);
    return;
  }
  Render(*mark, now);
  ShowWindow(mark->window, SW_SHOWNOACTIVATE);
  const size_t index = Stack(*mark);
  marks_.insert(marks_.begin() + index, std::move(mark));
  KeepOnTop();
}

std::unique_ptr<ScreenAnnotator::Mark> ScreenAnnotator::Build(
    const Command& command, bool on_board) {
  // The drawing space: the virtual desktop, or the whiteboard's canvas.
  double ox, oy, sw, sh, unit;
  if (on_board) {
    ox = board_->canvas.X;
    oy = board_->canvas.Y;
    sw = board_->canvas.Width;
    sh = board_->canvas.Height;
    unit = sh / 640.0;
  } else {
    ox = GetSystemMetrics(SM_XVIRTUALSCREEN);
    oy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    sw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    sh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    unit = GetSystemMetrics(SM_CYSCREEN) / 1000.0;
  }
  auto px = [&](double x) { return ox + std::clamp(x, 0.0, 1000.0) / 1000 * sw; };
  auto py = [&](double y) { return oy + std::clamp(y, 0.0, 1000.0) / 1000 * sh; };
  const auto& n = command.numbers;
  const std::string& type = command.type;
  const uint32_t serial = ++serial_;

  auto mark = std::make_unique<Mark>();
  mark->type = type;
  mark->rank = RankOf(type);
  mark->halo = !on_board;
  mark->width = static_cast<float>(std::max(3.0, unit * 3.6));
  std::vector<Gdiplus::PointF> points;
  double left = 0, top = 0, right = 0, bottom = 0;

  auto segment = [&](double x1, double y1, double x2, double y2, double seed) {
    const int steps = 24;
    const double length = std::hypot(x2 - x1, y2 - y1);
    const double nx = length > 0 ? -(y2 - y1) / length : 0;
    const double ny = length > 0 ? (x2 - x1) / length : 0;
    for (int i = 0; i <= steps; ++i) {
      const double t = static_cast<double>(i) / steps;
      const double sway = Wobble(t, seed) * mark->width * 0.35;
      points.emplace_back(static_cast<float>(x1 + (x2 - x1) * t + nx * sway),
                          static_cast<float>(y1 + (y2 - y1) * t + ny * sway));
    }
  };

  if ((type == "circle" || type == "box" || type == "highlight" ||
       type == "underline") &&
      n.size() >= 4) {
    RECT target{static_cast<LONG>(px(n[0])), static_cast<LONG>(py(n[1])),
                static_cast<LONG>(px(n[2])), static_cast<LONG>(py(n[3]))};
    // Models aim approximately; settle on what is really there: the named
    // words when OCR finds them, otherwise the content under the aim.
    if (!on_board) {
      const auto words = command.target.empty()
                             ? std::nullopt
                             : screen_text::Locate(command.target, target);
      target = words ? RECT{words->left - 2, words->top - 1, words->right + 2,
                            words->bottom + 1}
                     : command.exact ? target : Snap(type, target);
    }
    const double x1 = target.left, y1 = target.top;
    const double x2 = target.right, y2 = target.bottom;
    if (type == "circle") {
      // A loose loop around the target, overshooting where it began.
      const double cx = (x1 + x2) / 2, cy = (y1 + y2) / 2;
      const double rx = std::max(12.0, (x2 - x1) / 2 * 1.16 + mark->width * 2);
      const double ry = std::max(12.0, (y2 - y1) / 2 * 1.3 + mark->width * 2);
      const int steps = 72;
      const double begin = -kPi * 0.6;
      for (int i = 0; i <= steps; ++i) {
        const double t = static_cast<double>(i) / steps;
        const double angle = begin + t * kPi * 2.12;
        const double r = 1.02 + 0.04 * Wobble(t, 1.3) - 0.04 * t;
        points.emplace_back(static_cast<float>(cx + std::cos(angle) * rx * r),
                            static_cast<float>(cy + std::sin(angle) * ry * r));
      }
    } else if (type == "box") {
      const double pad = mark->width * 1.5;
      segment(x1 - pad, y1 - pad, x2 + pad, y1 - pad, 0.3);
      segment(x2 + pad, y1 - pad, x2 + pad, y2 + pad, 1.1);
      segment(x2 + pad, y2 + pad, x1 - pad, y2 + pad, 2.2);
      segment(x1 - pad, y2 + pad, x1 - pad, y1 - pad - mark->width, 3.4);
    } else if (type == "underline") {
      const double y = y2 + mark->width * 1.2;
      segment(x1, y, x2, y, 0.7);
    } else {
      // A highlighter stroke, a touch beyond the words.
      left = x1 - 3;
      right = x2 + 3;
      top = y1 - 2;
      bottom = y2 + 2;
      mark->color = Ink(command.color, "yellow", 100);
      mark->duration = std::clamp((right - left) / 1400.0, 0.3, 0.9);
    }
  } else if ((type == "line" || type == "arrow") && n.size() >= 4) {
    const double x1 = px(n[0]), y1 = py(n[1]);
    double x2 = px(n[2]), y2 = py(n[3]);
    if (!on_board && type == "arrow" && !command.target.empty()) {
      // Point at the named words themselves, stopping just short of them.
      const LONG reach = static_cast<LONG>(std::max(40.0, unit * 40));
      const RECT aim{static_cast<LONG>(x2) - reach, static_cast<LONG>(y2) - reach / 2,
                     static_cast<LONG>(x2) + reach, static_cast<LONG>(y2) + reach / 2};
      if (const auto words = screen_text::Locate(command.target, aim)) {
        AimAt(*words, x1, y1, mark->width * 2.5, &x2, &y2);
      }
    }
    segment(x1, y1, x2, y2, 0.7);
    if (type == "arrow") {
      const double angle = std::atan2(y2 - y1, x2 - x1);
      const double size = std::max(14.0, unit * 16);
      for (double side : {-1.0, 1.0}) {
        const double a = angle + kPi + side * 0.45;
        mark->head.emplace_back(static_cast<float>(x2), static_cast<float>(y2));
        mark->head.emplace_back(static_cast<float>(x2 + std::cos(a) * size),
                                static_cast<float>(y2 + std::sin(a) * size));
      }
    }
  } else if (type == "path" && command.points.size() >= 2) {
    for (const auto& [x, y] : command.points) {
      points.emplace_back(static_cast<float>(px(x)), static_cast<float>(py(y)));
    }
  } else if (type == "text" && n.size() >= 2 && !command.text.empty()) {
    const double scale = command.size == "s" ? 24 : command.size == "l" ? 52 : 36;
    const float size = static_cast<float>(std::max(16.0, unit * scale));
    mark->color = Ink(command.color, on_board ? "black" : "blue", 245);
    Random random(serial * 7919 + 17);
    Gdiplus::Bitmap probe(1, 1);
    Gdiplus::Graphics measure(&probe);
    const Gdiplus::StringFormat* format =
        Gdiplus::StringFormat::GenericTypographic();
    // The handwriting fonts (several MB) load only once a note is written.
    if (!fonts_) fonts_ = std::make_unique<Fonts>();
    const double origin_x = px(n[0]);
    double x = origin_x, y = py(n[1]), clock = 0;
    for (wchar_t c : command.text) {
      if (c == L'\n') {  // a new line under the first
        x = origin_x;
        y += size * 1.35;
        clock += 0.2;
        continue;
      }
      if (c == L' ' || c == L'\t' || c == L'\r') {
        x += size * 0.3;
        clock += 0.08;
        continue;
      }
      Gdiplus::FontFamily* family = fonts_->For(c);
      if (!family) continue;
      const bool cjk = IsCjk(c);
      // Hand-written Chinese looks small and fine-stroked beside Latin at
      // the same size: write it a little larger and with more ink.
      const float glyph_size = cjk ? size * 1.15f : size;
      Gdiplus::Font font(family, glyph_size, Gdiplus::FontStyleRegular,
                         Gdiplus::UnitPixel);
      Gdiplus::RectF box;
      measure.MeasureString(&c, 1, &font, Gdiplus::PointF(0, 0), format, &box);
      Mark::Glyph glyph;
      glyph.path = std::make_unique<Gdiplus::GraphicsPath>();
      glyph.path->AddString(&c, 1, family, Gdiplus::FontStyleRegular,
                            glyph_size, Gdiplus::PointF(0, 0), format);
      glyph.weight = cjk ? std::max(1.0f, size * 0.045f) : size * 0.012f;
      // Nobody writes two letters alike: a little tilt, size and baseline
      // drift, and uneven spacing.
      const double grow = random.Range(0.92, 1.07);
      const double drift = random.Range(-0.045, 0.045) * size +
                           std::sin(x * 0.011) * size * 0.03;
      Gdiplus::Matrix transform;
      transform.Translate(static_cast<float>(x), static_cast<float>(y + drift));
      transform.RotateAt(static_cast<float>(random.Range(-4.5, 4.5)),
                         Gdiplus::PointF(box.Width / 2, box.Height / 2));
      transform.Scale(static_cast<float>(grow), static_cast<float>(grow));
      glyph.path->Transform(&transform);
      glyph.path->GetBounds(&glyph.bounds);
      glyph.length = cjk ? 0.3 : IsAscii(c) ? 0.1 : 0.14;
      glyph.begin = clock;
      clock += glyph.length + random.Range(0.02, 0.08);
      x += box.Width * grow + size * random.Range(cjk ? -0.02 : -0.03, 0.05);
      mark->glyphs.push_back(std::move(glyph));
    }
    if (mark->glyphs.empty()) return nullptr;
    left = right = mark->glyphs.front().bounds.X;
    top = bottom = mark->glyphs.front().bounds.Y;
    for (const auto& glyph : mark->glyphs) {
      left = std::min<double>(left, glyph.bounds.X);
      top = std::min<double>(top, glyph.bounds.Y);
      right = std::max<double>(right, glyph.bounds.X + glyph.bounds.Width);
      bottom = std::max<double>(bottom, glyph.bounds.Y + glyph.bounds.Height);
    }
    mark->duration = std::max(0.3, clock);
  } else {
    return nullptr;  // Malformed: ignore rather than draw something wrong.
  }

  if (!points.empty()) {
    left = right = points.front().X;
    top = bottom = points.front().Y;
    double length = 0;
    for (size_t i = 0; i < points.size(); ++i) {
      left = std::min<double>(left, points[i].X);
      right = std::max<double>(right, points[i].X);
      top = std::min<double>(top, points[i].Y);
      bottom = std::max<double>(bottom, points[i].Y);
      if (i > 0) {
        length += std::hypot(points[i].X - points[i - 1].X,
                             points[i].Y - points[i - 1].Y);
      }
    }
    for (const auto& point : mark->head) {
      left = std::min<double>(left, point.X);
      right = std::max<double>(right, point.X);
      top = std::min<double>(top, point.Y);
      bottom = std::max<double>(bottom, point.Y);
    }
    // About the speed of a hand with a marker.
    mark->duration = std::clamp(length / 900.0, 0.45, 1.8);
    mark->color = Ink(command.color, "red", 235);
    mark->stroke = std::move(points);
  }
  mark->rect = Gdiplus::RectF(static_cast<float>(left), static_cast<float>(top),
                              static_cast<float>(right - left),
                              static_cast<float>(bottom - top));

  if (!on_board) {
    // A window just big enough for the mark and its halo.
    const int margin = static_cast<int>(mark->width * 3 + 10);
    mark->bounds = {static_cast<LONG>(std::floor(left)) - margin,
                    static_cast<LONG>(std::floor(top)) - margin,
                    static_cast<LONG>(std::ceil(right)) + margin,
                    static_cast<LONG>(std::ceil(bottom)) + margin};
    mark->Shift(static_cast<float>(mark->bounds.left),
                static_cast<float>(mark->bounds.top));
  }
  return mark;
}

// Finds what the model meant on the actual screen: the text line under a
// highlight or underline, or the content inside a circle or box. Falls back
// to the model's box whenever the screen does not give a clear answer.
RECT ScreenAnnotator::Snap(const std::string& type, RECT seed) const {
  const int sw = seed.right - seed.left, sh = seed.bottom - seed.top;
  if (sw < 6 || sh < 4) return seed;
  const int pad = std::max(12, std::max(sw, sh) / 3);
  const int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const RECT area{
      std::max<LONG>(seed.left - pad, vx), std::max<LONG>(seed.top - pad, vy),
      std::min<LONG>(seed.right + pad, vx + GetSystemMetrics(SM_CXVIRTUALSCREEN)),
      std::min<LONG>(seed.bottom + pad, vy + GetSystemMetrics(SM_CYVIRTUALSCREEN))};
  const int w = area.right - area.left, h = area.bottom - area.top;
  if (w <= 2 || h <= 2 || static_cast<int64_t>(w) * h > 6000000) return seed;

  // What is on screen there; layered marks are not part of a plain copy.
  Surface shot;
  if (!CreateSurface(w, h, &shot)) {
    DestroySurface(&shot);
    return seed;
  }
  HDC screen = GetDC(nullptr);
  BitBlt(shot.dc, 0, 0, w, h, screen, area.left, area.top, SRCCOPY);
  ReleaseDC(nullptr, screen);
  GdiFlush();
  const auto* pixels = static_cast<const uint32_t*>(shot.bits);

  // The background is the most common colour around the edge.
  std::map<uint32_t, int> votes;
  auto vote = [&](int x, int y) { ++votes[pixels[y * w + x] & 0xF0F0F0]; };
  for (int x = 0; x < w; ++x) {
    vote(x, 0);
    vote(x, h - 1);
  }
  for (int y = 0; y < h; ++y) {
    vote(0, y);
    vote(w - 1, y);
  }
  uint32_t background = 0;
  int best = -1;
  for (const auto& [color, count] : votes) {
    if (count > best) {
      best = count;
      background = color;
    }
  }
  auto channel = [](uint32_t c, int shift) {
    return static_cast<int>((c >> shift) & 0xF0);
  };
  auto ink = [&](int x, int y) {
    const uint32_t c = pixels[y * w + x];
    return std::abs(channel(c, 16) - channel(background, 16)) +
               std::abs(channel(c, 8) - channel(background, 8)) +
               std::abs(channel(c, 0) - channel(background, 0)) >
           70;
  };

  const int sx1 = std::clamp<int>(seed.left - area.left, 0, w - 1);
  const int sx2 = std::clamp<int>(seed.right - area.left, sx1 + 1, w);
  const int sy1 = std::clamp<int>(seed.top - area.top, 0, h - 1);
  const int sy2 = std::clamp<int>(seed.bottom - area.top, sy1 + 1, h);
  RECT result = seed;

  // Wide, short targets are words on a line, whatever mark is asked for.
  const bool textual = type == "highlight" || type == "underline" ||
                       (sw >= sh * 2.2 && sh <= 160);
  if (textual) {
    // Rows with ink across the target's span form text lines; take the line
    // that best overlaps the target.
    std::vector<int> rows(h, 0);
    for (int y = 0; y < h; ++y) {
      for (int x = sx1; x < sx2; ++x) rows[y] += ink(x, y) ? 1 : 0;
    }
    const int needed = std::max(2, (sx2 - sx1) / 50);
    int line_top = -1, line_bottom = -1;
    double best_score = -1e9;
    for (int y = 0; y < h;) {
      if (rows[y] < needed) {
        ++y;
        continue;
      }
      int end = y;
      while (end + 1 < h && (rows[end + 1] >= needed ||
                             (end + 2 < h && rows[end + 2] >= needed))) {
        ++end;
      }
      const int overlap = std::min(end + 1, sy2) - std::max(y, sy1);
      const double middle = (y + end) / 2.0;
      const double score = overlap - std::abs(middle - (sy1 + sy2) / 2.0) * 0.5;
      if (score > best_score) {
        best_score = score;
        line_top = y;
        line_bottom = end + 1;
      }
      y = end + 1;
    }
    if (line_top >= 0) {
      const int line = line_bottom - line_top;
      // Words on that line: runs of inked columns, split where the gap is
      // wider than a word space. Keep the words the target's core touches,
      // so neighbouring words and window borders stay out.
      std::vector<std::pair<int, int>> words;
      const int split = std::max(4, line / 2);
      int run_start = -1, run_end = -1;
      for (int x = 0; x < w; ++x) {
        bool inked = false;
        for (int y = line_top; y < line_bottom && !inked; ++y) {
          inked = ink(x, y);
        }
        if (!inked) continue;
        if (run_start >= 0 && x - run_end > split) {
          words.emplace_back(run_start, run_end);
          run_start = -1;
        }
        if (run_start < 0) run_start = x;
        run_end = x + 1;
      }
      if (run_start >= 0) words.emplace_back(run_start, run_end);
      const int core1 = sx1 + (sx2 - sx1) * 15 / 100;
      const int core2 = sx2 - (sx2 - sx1) * 15 / 100;
      int left = -1, right = -1;
      for (const auto& [a, b] : words) {
        if (b <= core1 || a >= core2) continue;
        if (left < 0) left = a;
        right = b;
      }
      const bool plausible = line >= 6 && line <= std::max(sh * 3, 60) &&
                             left >= 0 && (right - left) >= sw * 0.3 &&
                             (right - left) <= sw * 1.6;
      if (plausible) {
        result = {area.left + left - 2, area.top + line_top - 2,
                  area.left + right + 2, area.top + line_bottom + 2};
      }
    }
  } else {
    // The content inside the target, widened a little in case it was
    // aimed short.
    const int ex = sw / 8, ey = sh / 8;
    const int x1 = std::max(0, sx1 - ex), x2 = std::min(w, sx2 + ex);
    const int y1 = std::max(0, sy1 - ey), y2 = std::min(h, sy2 + ey);
    int left = w, top = h, right = -1, bottom = -1, count = 0;
    for (int y = y1; y < y2; ++y) {
      for (int x = x1; x < x2; ++x) {
        if (!ink(x, y)) continue;
        ++count;
        left = std::min(left, x);
        right = std::max(right, x + 1);
        top = std::min(top, y);
        bottom = std::max(bottom, y + 1);
      }
    }
    const bool plausible = count >= 20 && (right - left) >= sw * 0.35 &&
                           (bottom - top) >= sh * 0.35;
    if (plausible) {
      result = {area.left + left, area.top + top, area.left + right,
                area.top + bottom};
    }
  }
  DestroySurface(&shot);
  return result;
}

// Screen marks keep a fixed order: highlights, shapes, arrows, notes. Returns
// where the new mark belongs in [marks_], bottom to top.
size_t ScreenAnnotator::Stack(Mark& mark) {
  for (size_t i = 0; i < marks_.size(); ++i) {
    const auto& other = marks_[i];
    if (other->window && other->rank > mark.rank) {
      // Directly beneath the lowest mark that ranks above it.
      SetWindowPos(mark.window, other->window, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      return i;
    }
  }
  return marks_.size();  // newest window, already on top
}

// The whiteboard stays above screen marks, and a floating assistant window
// above everything drawn.
void ScreenAnnotator::KeepOnTop() {
  constexpr UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
  if (board_ && board_->window) {
    SetWindowPos(board_->window, HWND_TOPMOST, 0, 0, 0, 0, flags);
  }
  if (app_ && (GetWindowLongPtr(app_, GWL_EXSTYLE) & WS_EX_TOPMOST)) {
    SetWindowPos(app_, HWND_TOPMOST, 0, 0, 0, 0, flags | SWP_ASYNCWINDOWPOS);
  }
}

void ScreenAnnotator::Paint(void* graphics, const Mark& mark, double now,
                            double opacity) {
  auto& g = *static_cast<Gdiplus::Graphics*>(graphics);
  const double elapsed = now - mark.start;
  if (elapsed <= 0) return;
  const double eased = EaseOut(elapsed / mark.duration);
  auto round = [](Gdiplus::Pen& pen) {
    pen.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound,
                   Gdiplus::DashCapRound);
    pen.SetLineJoin(Gdiplus::LineJoinRound);
  };
  // A soft light halo keeps ink readable on a busy screen.
  const Gdiplus::Color halo =
      Scaled(Gdiplus::Color(150, 255, 255, 255), opacity);
  const Gdiplus::Color ink = Scaled(mark.color, opacity);

  if (!mark.stroke.empty()) {
    // Draw the first `eased` share of the stroke's length.
    double total = 0;
    for (size_t i = 1; i < mark.stroke.size(); ++i) {
      total += std::hypot(mark.stroke[i].X - mark.stroke[i - 1].X,
                          mark.stroke[i].Y - mark.stroke[i - 1].Y);
    }
    const double target = total * eased;
    std::vector<Gdiplus::PointF> drawn{mark.stroke.front()};
    double walked = 0;
    for (size_t i = 1; i < mark.stroke.size(); ++i) {
      const auto& a = mark.stroke[i - 1];
      const auto& b = mark.stroke[i];
      const double step = std::hypot(b.X - a.X, b.Y - a.Y);
      if (walked + step >= target) {
        const double t = step > 0 ? (target - walked) / step : 0;
        drawn.emplace_back(static_cast<float>(a.X + (b.X - a.X) * t),
                           static_cast<float>(a.Y + (b.Y - a.Y) * t));
        break;
      }
      drawn.push_back(b);
      walked += step;
    }
    Gdiplus::Pen outline(halo, mark.width + 4);
    Gdiplus::Pen line(ink, mark.width);
    round(outline);
    round(line);
    if (drawn.size() >= 2) {
      if (mark.halo) {
        g.DrawLines(&outline, drawn.data(), static_cast<INT>(drawn.size()));
      }
      g.DrawLines(&line, drawn.data(), static_cast<INT>(drawn.size()));
    }
    if (!mark.head.empty() && eased > 0.85) {
      for (size_t i = 0; i + 1 < mark.head.size(); i += 2) {
        if (mark.halo) g.DrawLine(&outline, mark.head[i], mark.head[i + 1]);
        g.DrawLine(&line, mark.head[i], mark.head[i + 1]);
      }
    }
  } else if (mark.type == "highlight") {
    // A marker swept from left to right.
    Gdiplus::SolidBrush brush(ink);
    const float width = static_cast<float>(mark.rect.Width * eased);
    if (width > 1) {
      Gdiplus::GraphicsPath sweep;
      AddRoundedRect(sweep,
                     Gdiplus::RectF(mark.rect.X, mark.rect.Y, width,
                                    mark.rect.Height),
                     std::min(4.0f, mark.rect.Height / 3));
      g.FillPath(&brush, &sweep);
    }
  } else if (mark.type == "text") {
    // Written glyph by glyph, each revealed in the pen's direction.
    Gdiplus::SolidBrush brush(ink);
    for (const auto& glyph : mark.glyphs) {
      const double written = (elapsed - glyph.begin) / glyph.length;
      if (written <= 0) break;
      const Gdiplus::RectF reveal(
          glyph.bounds.X - 3, glyph.bounds.Y - 6,
          static_cast<float>((glyph.bounds.Width + 6) * EaseOut(written)),
          glyph.bounds.Height + 12);
      Gdiplus::Region previous;
      g.GetClip(&previous);
      g.IntersectClip(reveal);
      if (mark.halo) {
        Gdiplus::Pen glow(halo, 5 + glyph.weight);
        round(glow);
        g.DrawPath(&glow, glyph.path.get());
      }
      g.FillPath(&brush, glyph.path.get());
      if (glyph.weight > 0) {
        Gdiplus::Pen body(ink, glyph.weight);
        round(body);
        g.DrawPath(&body, glyph.path.get());
      }
      g.SetClip(&previous);
    }
  }
}

void ScreenAnnotator::Render(Mark& mark, double now) {
  const int w = mark.bounds.right - mark.bounds.left;
  const int h = mark.bounds.bottom - mark.bounds.top;
  const double opacity =
      mark.fade < 0 ? 1.0
                    : std::clamp(1 - (now - mark.fade) / kFadeSeconds, 0.0, 1.0);
  {
    Gdiplus::Bitmap canvas(w, h, w * 4, PixelFormat32bppPARGB,
                           static_cast<BYTE*>(mark.surface.bits));
    Gdiplus::Graphics g(&canvas);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    Paint(&g, mark, now, opacity);
  }
  POINT position{mark.bounds.left, mark.bounds.top};
  Present(mark.window, mark.surface, w, h, &position);
  if (now - mark.start >= mark.duration && mark.fade < 0) mark.settled = true;
}

void ScreenAnnotator::OpenBoard(const std::wstring& title, double start) {
  if (board_ && board_->fade < 0 && board_->close_at < 0) {
    // A fresh page on the open board.
    board_->detached = false;
    board_->marks.clear();
    board_->ink.clear();
    board_->answering = false;
    board_->title = title;
    board_->start = start;
    board_->dirty = true;
    return;
  }
  DestroyBoard();
  auto board = std::make_unique<Board>();
  board->title = title;
  board->start = start;

  // On the monitor the user is looking at, beside the assistant's window.
  POINT cursor;
  GetCursorPos(&cursor);
  MONITORINFO monitor{sizeof(monitor)};
  GetMonitorInfo(MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY), &monitor);
  const RECT work = monitor.rcWork;
  const double work_w = work.right - work.left;
  const double work_h = work.bottom - work.top;
  board->header = static_cast<float>(std::max(40.0, work_h * 0.045));
  double panel_w = work_w * 0.6;
  double canvas_h = panel_w * 0.62;
  if (canvas_h + board->header > work_h * 0.84) {
    canvas_h = work_h * 0.84 - board->header;
    panel_w = canvas_h / 0.62;
  }
  board->margin = static_cast<float>(std::max(24.0, work_h * 0.02));
  board->width = static_cast<int>(panel_w + board->margin * 2);
  board->height =
      static_cast<int>(canvas_h + board->header + board->margin * 2);
  int x = static_cast<int>(work.left + (work_w - board->width) / 2);
  RECT app{};
  if (app_ && IsWindowVisible(app_) && GetWindowRect(app_, &app) &&
      app.right > work.left && app.left < work.right) {
    const double app_center = (app.left + app.right) / 2.0;
    x = app_center < work.left + work_w / 2
            ? static_cast<int>(work.right - board->width - work_w * 0.03)
            : static_cast<int>(work.left + work_w * 0.03);
  }
  const int y = static_cast<int>(work.top + (work_h - board->height) / 2);

  board->panel = Gdiplus::RectF(board->margin, board->margin,
                                static_cast<float>(panel_w),
                                static_cast<float>(canvas_h + board->header));
  const float inset = static_cast<float>(panel_w * 0.03);
  board->canvas = Gdiplus::RectF(
      board->panel.X + inset, board->panel.Y + board->header + inset * 0.5f,
      board->panel.Width - inset * 2, static_cast<float>(canvas_h) - inset * 1.5f);
  const float button = board->header * 0.5f;
  board->close = Gdiplus::RectF(
      board->panel.X + board->panel.Width - board->header * 0.75f - button / 2,
      board->panel.Y + (board->header - button) / 2, button, button);

  board->window = CreateWindowEx(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kBoardClass, L"Whiteboard", WS_POPUP, x, y, board->width, board->height,
      nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!board->window ||
      !CreateSurface(board->width, board->height, &board->surface)) {
    if (board->window) DestroyWindow(board->window);
    DestroySurface(&board->surface);
    return;
  }
  SetWindowLongPtr(board->window, GWLP_USERDATA,
                   reinterpret_cast<LONG_PTR>(this));
  SetWindowDisplayAffinity(board->window, kExcludeFromCapture);
  board_ = std::move(board);
  RenderBoard(Now());
  ShowWindow(board_->window, SW_SHOWNOACTIVATE);
  KeepOnTop();
}

void ScreenAnnotator::RenderBoard(double now) {
  Board& board = *board_;
  const double appear = std::clamp((now - board.start) / 0.3, 0.0, 1.0);
  const double opacity =
      (board.fade < 0
           ? 1.0
           : std::clamp(1 - (now - board.fade) / kFadeSeconds, 0.0, 1.0)) *
      EaseOut(appear);
  bool animating = appear < 1 || board.fade >= 0;
  {
    Gdiplus::Bitmap canvas(board.width, board.height, board.width * 4,
                           PixelFormat32bppPARGB,
                           static_cast<BYTE*>(board.surface.bits));
    Gdiplus::Graphics g(&canvas);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    const float radius = 14;
    // A soft shadow lifts the board above the screen and its marks.
    for (int ring = 10; ring >= 1; --ring) {
      Gdiplus::RectF spread = board.panel;
      spread.Inflate(ring * 1.8f, ring * 1.8f);
      spread.Offset(0, 5);
      Gdiplus::GraphicsPath shadow;
      AddRoundedRect(shadow, spread, radius + ring * 1.8f);
      Gdiplus::SolidBrush brush(Gdiplus::Color(
          static_cast<BYTE>((11 - ring) * 3.2 * opacity), 0, 0, 0));
      g.FillPath(&brush, &shadow);
    }
    Gdiplus::GraphicsPath surface;
    AddRoundedRect(surface, board.panel, radius);
    Gdiplus::SolidBrush paper(
        Scaled(Gdiplus::Color(255, 251, 251, 249), opacity));
    g.FillPath(&paper, &surface);
    // Title bar.
    g.SetClip(&surface);
    Gdiplus::SolidBrush bar(Scaled(Gdiplus::Color(255, 242, 242, 238), opacity));
    g.FillRectangle(&bar, board.panel.X, board.panel.Y, board.panel.Width,
                    board.header);
    g.ResetClip();
    Gdiplus::Pen rule(Scaled(Gdiplus::Color(255, 226, 226, 220), opacity), 1);
    g.DrawLine(&rule, board.panel.X, board.panel.Y + board.header,
               board.panel.X + board.panel.Width, board.panel.Y + board.header);
    Gdiplus::Pen frame(Scaled(Gdiplus::Color(255, 218, 218, 212), opacity), 1);
    g.DrawPath(&frame, &surface);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    bool chinese = false;
    for (wchar_t c : board.title) chinese = chinese || IsCjk(c);
    Gdiplus::FontFamily family(chinese ? L"Microsoft YaHei" : L"Segoe UI");
    Gdiplus::Font title_font(&family, board.header * 0.36f,
                             Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush muted(Scaled(Gdiplus::Color(255, 80, 84, 92), opacity));
    const std::wstring title =
        board.title.empty() ? std::wstring(L"Whiteboard") : board.title;
    Gdiplus::StringFormat middle;
    middle.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    middle.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    middle.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
    g.DrawString(title.c_str(), -1, &title_font,
                 Gdiplus::RectF(board.panel.X + board.header * 0.5f,
                                board.panel.Y,
                                board.panel.Width - board.header * 2,
                                board.header),
                 &middle, &muted);
    // Close button.
    Gdiplus::Pen cross(Scaled(Gdiplus::Color(255, 110, 114, 122), opacity),
                       1.8f);
    cross.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound,
                     Gdiplus::DashCapRound);
    const auto& c = board.close;
    const float k = c.Width * 0.28f;
    g.DrawLine(&cross, c.X + k, c.Y + k, c.X + c.Width - k, c.Y + c.Height - k);
    g.DrawLine(&cross, c.X + c.Width - k, c.Y + k, c.X + k, c.Y + c.Height - k);

    if (board.answering) {
      // Submit (filled) and Clear (outlined), left of the close button.
      Gdiplus::FontFamily ui(L"Microsoft YaHei");
      Gdiplus::Font label(&ui, board.header * 0.3f, Gdiplus::FontStyleRegular,
                          Gdiplus::UnitPixel);
      Gdiplus::StringFormat centered;
      centered.SetAlignment(Gdiplus::StringAlignmentCenter);
      centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      Gdiplus::GraphicsPath submit;
      AddRoundedRect(submit, board.submit, board.submit.Height / 2);
      Gdiplus::SolidBrush accent(
          Scaled(Gdiplus::Color(255, 37, 99, 235), opacity));
      g.FillPath(&accent, &submit);
      Gdiplus::SolidBrush white(Scaled(Gdiplus::Color(255, 255, 255, 255), opacity));
      g.DrawString(board.submit_label.c_str(), -1, &label, board.submit,
                   &centered, &white);
      Gdiplus::GraphicsPath clear;
      AddRoundedRect(clear, board.clear, board.clear.Height / 2);
      Gdiplus::Pen outline(Scaled(Gdiplus::Color(255, 200, 200, 194), opacity), 1);
      g.DrawPath(&outline, &clear);
      g.DrawString(board.clear_label.c_str(), -1, &label, board.clear,
                   &centered, &muted);
    }

    g.SetClip(&surface);
    for (const auto& mark : board.marks) {
      Paint(&g, *mark, now, opacity);
      animating = animating || now - mark->start < mark->duration;
    }
    PaintInk(&g, board, opacity);
    g.ResetClip();
  }
  // Keep wherever the user dragged it.
  Present(board.window, board.surface, board.width, board.height, nullptr);
  board.dirty = animating;
}

// Lets the student answer on the board: Submit and Clear appear in its title
// bar, and the canvas takes handwriting.
void ScreenAnnotator::StartExercise(const std::wstring& labels, double now) {
  if (!board_ || board_->fade >= 0 || board_->close_at >= 0) {
    OpenBoard(L"", now);
  }
  if (!board_) return;
  Board& board = *board_;
  board.detached = false;
  const size_t split = labels.find(L'\n');
  board.submit_label = split == std::wstring::npos ? L"Submit"
                                                   : labels.substr(0, split);
  board.clear_label = split == std::wstring::npos ? L"Clear"
                                                  : labels.substr(split + 1);
  board.answering = true;
  board.ink.clear();
  const float height = board.header * 0.62f;
  const float width = board.header * 2.1f;
  const float top = board.panel.Y + (board.header - height) / 2;
  board.submit = Gdiplus::RectF(board.close.X - board.header * 0.35f - width,
                                top, width, height);
  board.clear = Gdiplus::RectF(board.submit.X - board.header * 0.25f - width,
                               top, width, height);
  board.dirty = true;
  // Taking pen input needs the board in front of the marks and the app.
  SetWindowPos(board.window, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void ScreenAnnotator::PaintInk(void* graphics, const Board& board,
                               double opacity) {
  auto& g = *static_cast<Gdiplus::Graphics*>(graphics);
  Gdiplus::Pen pen(Scaled(Gdiplus::Color(255, 30, 58, 138), opacity),
                   std::max(2.5f, board.canvas.Height / 640 * 3.2f));
  pen.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound,
                 Gdiplus::DashCapRound);
  pen.SetLineJoin(Gdiplus::LineJoinRound);
  for (const auto& stroke : board.ink) {
    if (stroke.size() == 1) {
      const float d = pen.GetWidth();
      Gdiplus::SolidBrush dot(Scaled(Gdiplus::Color(255, 30, 58, 138), opacity));
      g.FillEllipse(&dot, stroke[0].X - d / 2, stroke[0].Y - d / 2, d, d);
    } else if (stroke.size() == 2) {
      g.DrawLine(&pen, stroke[0], stroke[1]);
    } else {
      // A gentle curve through the points smooths out mouse jitter.
      g.DrawCurve(&pen, stroke.data(), static_cast<INT>(stroke.size()), 0.4f);
    }
  }
}

// The canvas as the student sees it: question, marks and their answer,
// as a JPEG, in the board's 0..1000 space.
bool ScreenAnnotator::SnapshotBoard(std::vector<uint8_t>* jpeg) {
  if (!board_) return false;
  const Board& board = *board_;
  const int w = static_cast<int>(board.canvas.Width);
  const int h = static_cast<int>(board.canvas.Height);
  if (w <= 0 || h <= 0) return false;
  Gdiplus::Bitmap image(w, h, PixelFormat32bppRGB);
  {
    Gdiplus::Graphics g(&image);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.Clear(Gdiplus::Color(255, 251, 251, 249));
    g.TranslateTransform(-board.canvas.X, -board.canvas.Y);
    // Everything fully drawn, whatever is still animating.
    for (const auto& mark : board.marks) Paint(&g, *mark, 1e12, 1.0);
    PaintInk(&g, board, 1.0);
  }
  return EncodeJpeg(image, jpeg);
}

void ScreenAnnotator::DestroyBoard() {
  if (!board_) return;
  if (board_->window) DestroyWindow(board_->window);
  DestroySurface(&board_->surface);
  board_.reset();
}

LRESULT CALLBACK ScreenAnnotator::BoardProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<ScreenAnnotator*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
  if (self && self->board_ && self->board_->window == window) {
    Board& board = *self->board_;
    switch (message) {
      case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
      case WM_NCHITTEST: {
        POINT point{static_cast<short>(LOWORD(lparam)),
                    static_cast<short>(HIWORD(lparam))};
        ScreenToClient(window, &point);
        const Gdiplus::PointF p(static_cast<float>(point.x),
                                static_cast<float>(point.y));
        if (board.close.Contains(p)) return HTCLIENT;
        if (board.answering &&
            (board.submit.Contains(p) || board.clear.Contains(p))) {
          return HTCLIENT;
        }
        if (board.panel.Contains(p) &&
            p.Y < board.panel.Y + board.header) {
          return HTCAPTION;  // drag by the title bar
        }
        return HTCLIENT;
      }
      case WM_SETCURSOR: {
        POINT point;
        GetCursorPos(&point);
        ScreenToClient(window, &point);
        const Gdiplus::PointF p(static_cast<float>(point.x),
                                static_cast<float>(point.y));
        if (board.answering && board.canvas.Contains(p)) {
          SetCursor(LoadCursor(nullptr, IDC_CROSS));
          return TRUE;
        }
        break;
      }
      case WM_LBUTTONDOWN: {
        const Gdiplus::PointF p(
            static_cast<float>(static_cast<short>(LOWORD(lparam))),
            static_cast<float>(static_cast<short>(HIWORD(lparam))));
        if (board.answering && board.canvas.Contains(p) && board.fade < 0) {
          board.inking = true;
          board.ink.push_back({p});
          SetCapture(window);
          self->RenderBoard(Now());
        }
        return 0;
      }
      case WM_MOUSEMOVE: {
        if (!board.inking) break;
        const auto& c = board.canvas;
        const Gdiplus::PointF p(
            std::clamp(static_cast<float>(static_cast<short>(LOWORD(lparam))),
                       c.X, c.X + c.Width),
            std::clamp(static_cast<float>(static_cast<short>(HIWORD(lparam))),
                       c.Y, c.Y + c.Height));
        auto& stroke = board.ink.back();
        const auto& last = stroke.back();
        if (std::hypot(p.X - last.X, p.Y - last.Y) >= 1.5f) {
          stroke.push_back(p);
          self->RenderBoard(Now());
        }
        return 0;
      }
      case WM_CAPTURECHANGED:
        board.inking = false;
        break;
      case WM_LBUTTONUP: {
        const Gdiplus::PointF p(
            static_cast<float>(static_cast<short>(LOWORD(lparam))),
            static_cast<float>(static_cast<short>(HIWORD(lparam))));
        if (board.inking) {
          // Where the pen lifted ends the stroke, even if the last moves
          // were merged away.
          const auto& c = board.canvas;
          board.ink.back().push_back(Gdiplus::PointF(
              std::clamp(p.X, c.X, c.X + c.Width),
              std::clamp(p.Y, c.Y, c.Y + c.Height)));
          board.inking = false;
          ReleaseCapture();
          self->RenderBoard(Now());
          return 0;
        }
        if (board.close.Contains(p) && board.fade < 0) {
          board.fade = Now();
          board.dirty = true;
        } else if (board.answering && board.clear.Contains(p)) {
          board.ink.clear();
          self->RenderBoard(Now());
        } else if (board.answering && board.submit.Contains(p) &&
                   !board.ink.empty()) {
          std::vector<uint8_t> jpeg;
          if (self->SnapshotBoard(&jpeg)) {
            auto* bytes = new std::vector<uint8_t>(std::move(jpeg));
            if (!PostMessage(self->app_, kBoardSubmitted, 0,
                             reinterpret_cast<LPARAM>(bytes))) {
              delete bytes;
            }
          }
          // The answer stays on the board for the teacher to mark.
          board.answering = false;
          self->RenderBoard(Now());
        }
        return 0;
      }
    }
  }
  return DefWindowProc(window, message, wparam, lparam);
}

void ScreenAnnotator::Destroy(Mark& mark) {
  DestroySurface(&mark.surface);
  if (mark.window) DestroyWindow(mark.window);
  mark.window = nullptr;
}
