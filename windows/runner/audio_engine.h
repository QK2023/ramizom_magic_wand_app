#ifndef RUNNER_AUDIO_ENGINE_H_
#define RUNNER_AUDIO_ENGINE_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// Speech audio for voice conversations, built on WASAPI.
//
// Compressed speech (MP3, AAC, FLAC...) from a speech API is decoded off the
// window thread with Media Foundation before it is queued.
//
// Playback queues 16-bit mono PCM sentence by sentence and plays it without
// gaps; a frame counter lets captions follow the voice, and stopping is
// immediate. Capture delivers 16 kHz mono PCM from a "communications" stream,
// so Windows applies the device's echo cancellation and noise suppression
// where available, which lets the user talk over a spoken reply.
class AudioEngine {
 public:
  // Posted by the capture thread with a heap-allocated chunk.
  static constexpr UINT kCaptureMessage = WM_APP + 73;
  // Posted by a decoding thread with its finished job.
  static constexpr UINT kDecodeMessage = WM_APP + 74;

  AudioEngine(HWND window, flutter::BinaryMessenger* messenger);
  ~AudioEngine();

  // Window thread: forwards a captured chunk to Dart.
  void DeliverCapture(WPARAM session, LPARAM chunk);
  // Window thread: answers a decode request.
  static void DeliverDecode(LPARAM job);

 private:
  void Play(const std::vector<uint8_t>& pcm, int sample_rate);
  // Opens the output device ahead of the first sentence.
  void EnsureRenderThread(int sample_rate);
  void StopPlayback();
  void RenderLoop(int sample_rate);
  void StartCapture();
  void StopCapture();
  void CaptureLoop(int session);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  // Playback state shared with the render thread.
  std::mutex mutex_;
  std::deque<int16_t> queue_;
  int64_t queued_ = 0;              // frames ever queued (monotonic)
  std::atomic<int64_t> played_{0};  // frames handed to the device
  std::thread render_thread_;
  std::atomic<bool> render_running_{false};
  std::atomic<bool> render_stop_{false};
  int render_rate_ = 0;

  std::thread capture_thread_;
  std::atomic<bool> capture_stop_{false};
  std::atomic<int> capture_session_{0};
};

#endif  // RUNNER_AUDIO_ENGINE_H_
