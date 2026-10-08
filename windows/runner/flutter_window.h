#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "audio_engine.h"
#include "screen_annotator.h"
#include "screen_glow.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Posted by the capture worker when a screen frame is ready.
  static constexpr UINT kCaptureMessage = WM_APP + 72;

  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<ScreenGlow> glow_;
  std::unique_ptr<AudioEngine> audio_;
  std::unique_ptr<ScreenAnnotator> annotator_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> annotate_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screen_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
