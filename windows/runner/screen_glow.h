#ifndef RUNNER_SCREEN_GLOW_H_
#define RUNNER_SCREEN_GLOW_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

struct GlowRgb {
  double r, g, b;
};

// A flowing light around every monitor edge while the screen is shared.
// The strips are click-through, never activate, and are excluded from screen
// capture so the model never sees them. All window work happens on a private
// thread so animation never competes with the Flutter window thread.
class ScreenGlow {
 public:
  ScreenGlow();
  ~ScreenGlow();
  void Show();
  void Hide();

 private:
  enum class Edge { kTop, kRight, kBottom, kLeft };
  struct Strip {
    HWND window = nullptr;
    HDC dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    uint32_t* pixels = nullptr;
    Edge edge = Edge::kTop;
    RECT monitor{};
    RECT bounds{};
    int thickness = 0;
  };

  void Run();
  void CreateStrips();
  void DestroyStrips();
  void Render(Strip& strip);

  std::thread thread_;
  HANDLE wake_ = nullptr;
  std::atomic<bool> visible_{false};
  std::atomic<bool> quit_{false};
  std::vector<Strip> strips_;
  // Per-perimeter colour and depth, shared by a monitor's four strips.
  std::vector<GlowRgb> colors_;
  std::vector<double> extents_;
  uint64_t frame_ = 0;
  uint64_t frame_key_ = ~0ull;
  RECT frame_monitor_{};
  int frame_size_ = 0;
  double intensity_ = 0;
  double phase_ = 0;
  double wave_ = 0;
};

#endif  // RUNNER_SCREEN_GLOW_H_
