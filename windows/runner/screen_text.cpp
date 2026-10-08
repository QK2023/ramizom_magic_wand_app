#include "screen_text.h"

#include <unknwn.h>
#include <gdiplus.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <mutex>
#include <thread>

namespace screen_text {
namespace {

using winrt::Windows::Graphics::Imaging::BitmapAlphaMode;
using winrt::Windows::Graphics::Imaging::BitmapPixelFormat;
using winrt::Windows::Graphics::Imaging::SoftwareBitmap;
using winrt::Windows::Media::Ocr::OcrEngine;
using winrt::Windows::Storage::Streams::DataWriter;

bool IsCjk(wchar_t c) {
  return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) ||
         (c >= 0xF900 && c <= 0xFAFF);
}

// Runs [work] on a thread of its own in the multithreaded apartment: WinRT's
// blocking get() is not allowed on window threads.
template <typename Work>
void InMta(Work&& work) {
  std::thread worker([&work] {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      work();
    } catch (...) {
      // No OCR: callers fall back to what they had.
    }
    winrt::uninit_apartment();
  });
  worker.join();
}

// OCR engines for Chinese, for English and for the user's own languages.
// Engines are agile, so one set serves every thread.
struct Engines {
  OcrEngine chinese{nullptr};
  OcrEngine english{nullptr};
  OcrEngine user{nullptr};
};

const Engines& GetEngines() {
  static std::mutex mutex;
  static Engines engines;
  static bool loaded = false;
  std::lock_guard<std::mutex> lock(mutex);
  if (!loaded) {
    loaded = true;
    for (const auto& language : OcrEngine::AvailableRecognizerLanguages()) {
      const std::wstring tag(language.LanguageTag());
      if (tag.rfind(L"zh-Hans", 0) == 0 ||
          (!engines.chinese && tag.rfind(L"zh", 0) == 0)) {
        engines.chinese = OcrEngine::TryCreateFromLanguage(language);
      } else if (!engines.english && tag.rfind(L"en", 0) == 0) {
        engines.english = OcrEngine::TryCreateFromLanguage(language);
      }
    }
    engines.user = OcrEngine::TryCreateFromUserProfileLanguages();
  }
  return engines;
}

// Chinese text needs a Chinese engine; Latin text reads best with English,
// and a Chinese engine reads Latin too.
OcrEngine EngineFor(bool cjk) {
  const Engines& e = GetEngines();
  if (cjk) return e.chinese ? e.chinese : e.user;
  if (e.english) return e.english;
  return e.user ? e.user : e.chinese;
}

// The screen's pixels in [area], scaled by [scale], as opaque BGRA.
bool Grab(RECT area, double scale, int* out_w, int* out_h,
          std::vector<uint8_t>* out) {
  const int w = area.right - area.left, h = area.bottom - area.top;
  if (w <= 0 || h <= 0) return false;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = w;
  info.bmiHeader.biHeight = -h;  // top-down
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
    // A plain copy: the assistant's own marks and windows are excluded from
    // capture and layered marks are left out, so only the user's content
    // is read.
    ok = BitBlt(memory, 0, 0, w, h, screen, area.left, area.top, SRCCOPY) != 0;
    GdiFlush();
    SelectObject(memory, old);
  }
  ReleaseDC(nullptr, screen);
  if (memory) DeleteDC(memory);
  if (ok) {
    if (scale == 1.0) {
      const auto* first = static_cast<const uint8_t*>(bits);
      out->assign(first, first + static_cast<size_t>(w) * h * 4);
      *out_w = w;
      *out_h = h;
    } else {
      // Small screen text reads far better enlarged smoothly.
      const int sw = std::max(1, static_cast<int>(std::lround(w * scale)));
      const int sh = std::max(1, static_cast<int>(std::lround(h * scale)));
      Gdiplus::GdiplusStartupInput input;
      ULONG_PTR token = 0;
      ok = Gdiplus::GdiplusStartup(&token, &input, nullptr) == Gdiplus::Ok;
      if (ok) {
        {
          Gdiplus::Bitmap source(w, h, w * 4, PixelFormat32bppRGB,
                                 static_cast<BYTE*>(bits));
          Gdiplus::Bitmap target(sw, sh, PixelFormat32bppARGB);
          {
            Gdiplus::Graphics g(&target);
            g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
            g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
            g.DrawImage(&source, Gdiplus::Rect(0, 0, sw, sh), 0, 0, w, h,
                        Gdiplus::UnitPixel);
          }
          Gdiplus::BitmapData data{};
          Gdiplus::Rect all(0, 0, sw, sh);
          ok = target.LockBits(&all, Gdiplus::ImageLockModeRead,
                               PixelFormat32bppARGB, &data) == Gdiplus::Ok;
          if (ok) {
            out->resize(static_cast<size_t>(sw) * sh * 4);
            for (int y = 0; y < sh; ++y) {
              std::memcpy(out->data() + static_cast<size_t>(y) * sw * 4,
                          static_cast<const uint8_t*>(data.Scan0) +
                              static_cast<ptrdiff_t>(y) * data.Stride,
                          static_cast<size_t>(sw) * 4);
            }
            target.UnlockBits(&data);
            *out_w = sw;
            *out_h = sh;
          }
        }
        Gdiplus::GdiplusShutdown(token);
      }
    }
  }
  if (dib) DeleteObject(dib);
  if (!ok) return false;
  for (size_t i = 3; i < out->size(); i += 4) (*out)[i] = 255;
  return true;
}

// The text lines in [area] of the screen.
std::vector<Line> Read(RECT area, double scale, bool cjk) {
  std::vector<Line> lines;
  int w = 0, h = 0;
  std::vector<uint8_t> pixels;
  scale = std::min(scale, 8000.0 / std::max<LONG>(1, std::max(
                                         area.right - area.left,
                                         area.bottom - area.top)));
  if (!Grab(area, scale, &w, &h, &pixels)) return lines;
  InMta([&] {
    OcrEngine engine = EngineFor(cjk);
    if (!engine) return;
    DataWriter writer;
    writer.WriteBytes(winrt::array_view<const uint8_t>(pixels));
    const SoftwareBitmap bitmap = SoftwareBitmap::CreateCopyFromBuffer(
        writer.DetachBuffer(), BitmapPixelFormat::Bgra8, w, h,
        BitmapAlphaMode::Premultiplied);
    const auto result = engine.RecognizeAsync(bitmap).get();
    for (const auto& ocr_line : result.Lines()) {
      Line line;
      line.text = std::wstring(ocr_line.Text());
      for (const auto& ocr_word : ocr_line.Words()) {
        const auto box = ocr_word.BoundingRect();
        Word word;
        word.text = std::wstring(ocr_word.Text());
        word.rect = {area.left + static_cast<LONG>(std::floor(box.X / scale)),
                     area.top + static_cast<LONG>(std::floor(box.Y / scale)),
                     area.left + static_cast<LONG>(
                                     std::ceil((box.X + box.Width) / scale)),
                     area.top + static_cast<LONG>(
                                    std::ceil((box.Y + box.Height) / scale))};
        if (line.words.empty()) {
          line.rect = word.rect;
        } else {
          UnionRect(&line.rect, &line.rect, &word.rect);
        }
        line.words.push_back(std::move(word));
      }
      if (!line.words.empty()) lines.push_back(std::move(line));
    }
  });
  return lines;
}

// Text compared loosely: case, spacing, punctuation, full-width forms and
// the letters OCR confuses with digits do not matter.
wchar_t Fold(wchar_t c) {
  if (c >= 0xFF01 && c <= 0xFF5E) c = static_cast<wchar_t>(c - 0xFEE0);
  if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
  if (c == L'0') return L'o';
  if (c == L'1' || c == L'i' || c == L'|') return L'l';
  if ((c >= L'a' && c <= L'z') || (c >= L'2' && c <= L'9') || c == L'o' ||
      c == L'l' || IsCjk(c)) {
    return c;
  }
  // Other letters (accented Latin, Cyrillic, Greek...) are kept as they are.
  if (c >= 0xC0 && c < 0x2000 && std::iswalpha(c)) {
    return static_cast<wchar_t>(std::towlower(c));
  }
  return 0;
}

std::wstring Normalize(const std::wstring& text) {
  std::wstring result;
  for (wchar_t c : text) {
    if (const wchar_t folded = Fold(c)) result.push_back(folded);
  }
  return result;
}

// One comparable character with where it sits on screen.
struct Glyph {
  wchar_t c;
  RECT rect;
  // The word's own edges, used when a match starts or ends the word, so
  // its punctuation and the OCR's word box come along.
  LONG word_left;
  LONG word_right;
  bool first;
  bool last;
};

void AddLine(const Line& line, std::vector<Glyph>* glyphs) {
  for (const Word& word : line.words) {
    // Characters share their word's box in proportion.
    const int count = static_cast<int>(word.text.size());
    const int width = word.rect.right - word.rect.left;
    const size_t begin = glyphs->size();
    for (int i = 0; i < count; ++i) {
      const wchar_t folded = Fold(word.text[i]);
      if (!folded) continue;
      const RECT rect{word.rect.left + width * i / count, word.rect.top,
                      word.rect.left + width * (i + 1) / count,
                      word.rect.bottom};
      glyphs->push_back(
          {folded, rect, word.rect.left, word.rect.right, false, false});
    }
    if (glyphs->size() > begin) {
      (*glyphs)[begin].first = true;
      glyphs->back().last = true;
    }
  }
}

// How many edits a target of [length] characters may differ by.
int Allowed(size_t length) {
  if (length <= 3) return 0;
  if (length <= 7) return 1;
  return static_cast<int>(length / 4);
}

struct Match {
  RECT rect;
  double score;
};

double Distance(const RECT& a, const RECT& b) {
  return std::hypot((a.left + a.right) / 2.0 - (b.left + b.right) / 2.0,
                    (a.top + a.bottom) / 2.0 - (b.top + b.bottom) / 2.0);
}

// The best place for [pattern] among [lines]: as close a match as possible,
// as near the model's aim as possible.
std::optional<Match> Best(const std::vector<Line>& lines,
                          const std::wstring& pattern, RECT seed,
                          double diagonal) {
  const size_t m = pattern.size();
  const int allowed = Allowed(m);
  std::optional<Match> best;
  for (size_t first = 0; first < lines.size(); ++first) {
    // A target may run on over the next lines of the same paragraph.
    std::vector<Glyph> text;
    for (size_t last = first; last < lines.size() && last < first + 3; ++last) {
      if (last > first) {
        const RECT& above = lines[last - 1].rect;
        const RECT& below = lines[last].rect;
        const LONG height = std::max<LONG>(1, above.bottom - above.top);
        const bool follows = below.top >= above.top + height / 2 &&
                             below.top - above.bottom <= height * 3 / 2 &&
                             below.left < above.right && below.right > above.left;
        if (!follows) break;
      }
      const size_t before = text.size();
      AddLine(lines[last], &text);
      if (text.size() == before || text.size() + allowed < m) continue;

      // Approximate substring search: the cheapest edit of the pattern into
      // any stretch of the text, remembering where each stretch starts.
      const size_t n = text.size();
      std::vector<int> cost(n + 1, 0), next(n + 1);
      std::vector<size_t> start(n + 1), next_start(n + 1);
      for (size_t j = 0; j <= n; ++j) start[j] = j;
      for (size_t i = 1; i <= m; ++i) {
        next[0] = static_cast<int>(i);
        next_start[0] = 0;
        for (size_t j = 1; j <= n; ++j) {
          int value = cost[j - 1] + (pattern[i - 1] == text[j - 1].c ? 0 : 1);
          size_t from = start[j - 1];
          if (cost[j] + 1 < value) {
            value = cost[j] + 1;
            from = start[j];
          }
          if (next[j - 1] + 1 < value) {
            value = next[j - 1] + 1;
            from = next_start[j - 1];
          }
          next[j] = value;
          next_start[j] = from;
        }
        std::swap(cost, next);
        std::swap(start, next_start);
      }
      for (size_t j = 1; j <= n; ++j) {
        if (cost[j] > allowed || start[j] >= j) continue;
        // Only the end of each run of good endings, the fullest match.
        if (j < n && cost[j + 1] <= cost[j] && start[j + 1] == start[j]) {
          continue;
        }
        RECT rect = text[start[j]].rect;
        for (size_t k = start[j] + 1; k < j; ++k) {
          UnionRect(&rect, &rect, &text[k].rect);
        }
        if (text[start[j]].first) {
          rect.left = std::min(rect.left, text[start[j]].word_left);
        }
        if (text[j - 1].last) {
          rect.right = std::max(rect.right, text[j - 1].word_right);
        }
        RECT overlap;
        double shared = 0;
        if (IntersectRect(&overlap, &rect, &seed)) {
          const double area = static_cast<double>(overlap.right - overlap.left) *
                              (overlap.bottom - overlap.top);
          const double whole = static_cast<double>(rect.right - rect.left) *
                               (rect.bottom - rect.top);
          shared = whole > 0 ? area / whole : 0;
        }
        const double quality = 1.0 - static_cast<double>(cost[j]) / m;
        const double score = quality + 0.2 * shared -
                             0.8 * Distance(rect, seed) / diagonal -
                             0.05 * static_cast<double>(last - first);
        if (!best || score > best->score) best = Match{rect, score};
      }
    }
  }
  return best;
}

// A whole monitor's text, kept briefly: one explanation draws several marks
// on the same screen.
struct MonitorCache {
  RECT monitor{};
  bool cjk = false;
  std::chrono::steady_clock::time_point time;
  std::vector<Line> lines;
};

}  // namespace

std::vector<Line> ReadDesktop() {
  std::vector<RECT> monitors;
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR, HDC, LPRECT rect, LPARAM data) -> BOOL {
        reinterpret_cast<std::vector<RECT>*>(data)->push_back(*rect);
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&monitors));
  std::vector<Line> all;
  // The user's own languages: the screen is mostly in them.
  bool cjk = false;
  {
    wchar_t name[LOCALE_NAME_MAX_LENGTH] = {};
    if (GetUserDefaultLocaleName(name, LOCALE_NAME_MAX_LENGTH) > 0) {
      cjk = std::wstring(name).rfind(L"zh", 0) == 0;
    }
  }
  for (const RECT& monitor : monitors) {
    // Enlarged a little when the monitor allows: small UI text reads better.
    const LONG height = monitor.bottom - monitor.top;
    auto lines = Read(monitor, height <= 1200 ? 1.5 : 1.0, cjk);
    for (auto& line : lines) all.push_back(std::move(line));
  }
  return all;
}

std::optional<RECT> Locate(const std::wstring& target, RECT seed) {
  const std::wstring pattern = Normalize(target);
  if (pattern.empty() || pattern.size() > 200) return std::nullopt;
  const bool cjk = std::any_of(target.begin(), target.end(), IsCjk);
  MONITORINFO info{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromRect(&seed, MONITOR_DEFAULTTONEAREST), &info)) {
    return std::nullopt;
  }
  const RECT monitor = info.rcMonitor;
  const double diagonal =
      std::hypot(monitor.right - monitor.left, monitor.bottom - monitor.top);
  const LONG sw = seed.right - seed.left, sh = seed.bottom - seed.top;

  // First around where the model aimed, enlarged for the smallest text.
  RECT around{seed.left - std::max<LONG>(240, sw), seed.top - std::max<LONG>(120, sh * 2),
            seed.right + std::max<LONG>(240, sw), seed.bottom + std::max<LONG>(120, sh * 2)};
  IntersectRect(&around, &around, &monitor);
  const double around_area = static_cast<double>(around.right - around.left) *
                             (around.bottom - around.top);
  if (around_area > 0) {
    const double scale = around_area * 4 <= 8e6 ? 2.0 : 1.5;
    if (auto found = Best(Read(around, scale, cjk), pattern, seed, diagonal)) {
      return found->rect;
    }
  }

  // Then anywhere on that monitor: the aim may have been well off.
  static std::mutex mutex;
  static MonitorCache cache;
  std::vector<Line> lines;
  {
    std::lock_guard<std::mutex> lock(mutex);
    const auto now = std::chrono::steady_clock::now();
    if (EqualRect(&cache.monitor, &monitor) && cache.cjk == cjk &&
        now - cache.time < std::chrono::seconds(4)) {
      lines = cache.lines;
    }
  }
  if (lines.empty()) {
    const LONG height = monitor.bottom - monitor.top;
    lines = Read(monitor, height <= 1200 ? 1.5 : 1.0, cjk);
    std::lock_guard<std::mutex> lock(mutex);
    cache = {monitor, cjk, std::chrono::steady_clock::now(), lines};
  }
  // Far from the aim, only a clear match is trusted.
  auto found = Best(lines, pattern, seed, diagonal);
  if (found && found->score >= 0.6) return found->rect;
  return std::nullopt;
}

}  // namespace screen_text
