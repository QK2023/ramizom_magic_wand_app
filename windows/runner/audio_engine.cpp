#include "audio_engine.h"

#include "audio_decoder.h"

#include <audioclient.h>
#include <audiopolicy.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <string>

using Microsoft::WRL::ComPtr;

namespace {

constexpr int kCaptureRate = 16000;
// Deliver ~100 ms of microphone audio per event.
constexpr size_t kCaptureChunkFrames = kCaptureRate / 10;
// A render thread with nothing to play exits after this many idle waits,
// so the audio device can sleep between replies.
constexpr int kIdleWaits = 1500;  // ~30 s at 20 ms

struct CaptureChunk {
  std::vector<uint8_t> bytes;
};

struct DecodeJob {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  std::vector<uint8_t> encoded;
  std::vector<int16_t> samples;
  int sample_rate = 0;
  std::string error;
  bool ok = false;
};

WAVEFORMATEX MonoPcm16(int sample_rate) {
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 1;
  format.nSamplesPerSec = sample_rate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = 2;
  format.nAvgBytesPerSec = sample_rate * 2;
  return format;
}

// Opens the default endpoint as a shared, event-driven stream that converts
// to and from 16-bit mono PCM at [sample_rate].
HRESULT OpenClient(EDataFlow flow, ERole role, AUDIO_STREAM_CATEGORY category,
                   int sample_rate, REFERENCE_TIME buffer,
                   ComPtr<IAudioClient2>* client, HANDLE event) {
  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) return hr;
  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(flow, role, &device);
  if (FAILED(hr)) return hr;
  hr = device->Activate(__uuidof(IAudioClient2), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(client->GetAddressOf()));
  if (FAILED(hr)) return hr;
  AudioClientProperties properties{};
  properties.cbSize = sizeof(properties);
  properties.eCategory = category;
  (*client)->SetClientProperties(&properties);
  WAVEFORMATEX format = MonoPcm16(sample_rate);
  hr = (*client)->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
          AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
      buffer, 0, &format, nullptr);
  if (FAILED(hr)) return hr;
  return (*client)->SetEventHandle(event);
}

}  // namespace

AudioEngine::AudioEngine(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  methods_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "ai.ramizom.magic_wand/audio",
      &flutter::StandardMethodCodec::GetInstance());
  methods_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    if (call.method_name() == "play" && arguments) {
      const auto samples = arguments->find(flutter::EncodableValue("samples"));
      const auto rate = arguments->find(flutter::EncodableValue("sampleRate"));
      const auto* bytes = samples == arguments->end()
                              ? nullptr
                              : std::get_if<std::vector<uint8_t>>(&samples->second);
      const auto* sample_rate =
          rate == arguments->end() ? nullptr : std::get_if<int32_t>(&rate->second);
      if (!bytes || !sample_rate) {
        result->Error("bad_arguments", "play needs samples and sampleRate");
        return;
      }
      Play(*bytes, *sample_rate);
      std::lock_guard<std::mutex> lock(mutex_);
      result->Success(flutter::EncodableValue(static_cast<int64_t>(queued_)));
    } else if (call.method_name() == "prepare" && arguments) {
      const auto rate = arguments->find(flutter::EncodableValue("sampleRate"));
      const auto* sample_rate =
          rate == arguments->end() ? nullptr : std::get_if<int32_t>(&rate->second);
      if (sample_rate) EnsureRenderThread(*sample_rate);
      result->Success();
    } else if (call.method_name() == "decode" && arguments) {
      const auto bytes = arguments->find(flutter::EncodableValue("bytes"));
      const auto* encoded =
          bytes == arguments->end()
              ? nullptr
              : std::get_if<std::vector<uint8_t>>(&bytes->second);
      if (!encoded) {
        result->Error("bad_arguments", "decode needs bytes");
        return;
      }
      auto* job = new DecodeJob();
      job->result = std::move(result);
      job->encoded = *encoded;
      std::thread([window = window_, job]() {
        job->ok = DecodeAudio(job->encoded, &job->samples, &job->sample_rate,
                              &job->error);
        job->encoded.clear();
        if (!PostMessage(window, kDecodeMessage, 0,
                         reinterpret_cast<LPARAM>(job))) {
          delete job;
        }
      }).detach();
    } else if (call.method_name() == "stopPlayback") {
      StopPlayback();
      result->Success();
    } else if (call.method_name() == "position") {
      int64_t queued;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        queued = queued_;
      }
      flutter::EncodableMap position{
          {flutter::EncodableValue("played"),
           flutter::EncodableValue(static_cast<int64_t>(played_.load()))},
          {flutter::EncodableValue("queued"), flutter::EncodableValue(queued)}};
      result->Success(flutter::EncodableValue(position));
    } else {
      result->NotImplemented();
    }
  });

  events_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "ai.ramizom.magic_wand/microphone",
      &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_ = std::move(events);
            StartCapture();
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            StopCapture();
            sink_.reset();
            return nullptr;
          }));
}

AudioEngine::~AudioEngine() {
  StopCapture();
  render_stop_ = true;
  if (render_thread_.joinable()) render_thread_.join();
  methods_->SetMethodCallHandler(nullptr);
  events_->SetStreamHandler(nullptr);
}

void AudioEngine::DeliverDecode(LPARAM lparam) {
  std::unique_ptr<DecodeJob> job(reinterpret_cast<DecodeJob*>(lparam));
  if (!job->ok) {
    job->result->Error("decode_failed", job->error);
    return;
  }
  const auto* first = reinterpret_cast<const uint8_t*>(job->samples.data());
  flutter::EncodableMap response{
      {flutter::EncodableValue("samples"),
       flutter::EncodableValue(std::vector<uint8_t>(
           first, first + job->samples.size() * sizeof(int16_t)))},
      {flutter::EncodableValue("sampleRate"),
       flutter::EncodableValue(job->sample_rate)}};
  job->result->Success(flutter::EncodableValue(response));
}

void AudioEngine::Play(const std::vector<uint8_t>& pcm, int sample_rate) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t frames = pcm.size() / 2;
    const auto* samples = reinterpret_cast<const int16_t*>(pcm.data());
    queue_.insert(queue_.end(), samples, samples + frames);
    queued_ += static_cast<int64_t>(frames);
    // The render thread only stops itself under this lock with an empty
    // queue, so a running thread is guaranteed to play what was just added.
    if (render_running_ && render_rate_ == sample_rate) return;
  }
  EnsureRenderThread(sample_rate);
}

void AudioEngine::EnsureRenderThread(int sample_rate) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (render_running_ && render_rate_ == sample_rate) return;
  }
  // (Re)start the render thread for this rate; queued audio is kept.
  render_stop_ = true;
  if (render_thread_.joinable()) render_thread_.join();
  render_stop_ = false;
  render_running_ = true;
  render_rate_ = sample_rate;
  render_thread_ = std::thread(&AudioEngine::RenderLoop, this, sample_rate);
}

void AudioEngine::StopPlayback() {
  std::lock_guard<std::mutex> lock(mutex_);
  queue_.clear();
  // Everything queued counts as played, so positions stay monotonic.
  played_ = queued_;
}

void AudioEngine::RenderLoop(int sample_rate) {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  HANDLE event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  ComPtr<IAudioClient2> client;
  ComPtr<IAudioRenderClient> render;
  UINT32 capacity = 0;
  bool ok = event &&
            SUCCEEDED(OpenClient(eRender, eConsole, AudioCategory_Speech,
                                 sample_rate, 300000, &client, event)) &&
            SUCCEEDED(client->GetBufferSize(&capacity)) &&
            SUCCEEDED(client->GetService(IID_PPV_ARGS(&render))) &&
            SUCCEEDED(client->Start());
  int idle = 0;
  while (ok && !render_stop_) {
    WaitForSingleObject(event, 20);
    UINT32 padding = 0;
    if (FAILED(client->GetCurrentPadding(&padding))) break;
    const UINT32 available = capacity - padding;
    if (available == 0) continue;
    BYTE* data = nullptr;
    if (FAILED(render->GetBuffer(available, &data))) break;
    auto* out = reinterpret_cast<int16_t*>(data);
    size_t written = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      written = std::min<size_t>(available, queue_.size());
      std::copy_n(queue_.begin(), written, out);
      queue_.erase(queue_.begin(), queue_.begin() + written);
      played_ += static_cast<int64_t>(written);
    }
    std::fill(out + written, out + available, int16_t{0});
    render->ReleaseBuffer(available, 0);
    // Idle only once the device has drained what was written.
    idle = written == 0 && padding == 0 ? idle + 1 : 0;
    if (idle > kIdleWaits) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (queue_.empty()) {
        render_running_ = false;
        break;
      }
      idle = 0;
    }
  }
  if (client) client->Stop();
  if (event) CloseHandle(event);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (render_running_ && !render_stop_) {
      // The device failed or vanished: drop what can no longer be played.
      queue_.clear();
      played_ = queued_;
    }
    render_running_ = false;
  }
  if (SUCCEEDED(com)) CoUninitialize();
}

void AudioEngine::StartCapture() {
  StopCapture();
  capture_stop_ = false;
  const int session = ++capture_session_;
  capture_thread_ = std::thread(&AudioEngine::CaptureLoop, this, session);
}

void AudioEngine::StopCapture() {
  ++capture_session_;
  capture_stop_ = true;
  if (capture_thread_.joinable()) capture_thread_.join();
}

void AudioEngine::CaptureLoop(int session) {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  HANDLE event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  ComPtr<IAudioClient2> client;
  ComPtr<IAudioCaptureClient> capture;
  HRESULT hr = event ? OpenClient(eCapture, eCommunications,
                                  AudioCategory_Communications, kCaptureRate,
                                  200000, &client, event)
                     : E_FAIL;
  if (SUCCEEDED(hr)) {
    // Opening a communications stream must not turn other apps down.
    ComPtr<IAudioSessionControl> control;
    ComPtr<IAudioSessionControl2> control2;
    if (SUCCEEDED(client->GetService(IID_PPV_ARGS(&control))) &&
        SUCCEEDED(control.As(&control2))) {
      control2->SetDuckingPreference(TRUE);
    }
    hr = client->GetService(IID_PPV_ARGS(&capture));
  }
  if (SUCCEEDED(hr)) hr = client->Start();
  if (FAILED(hr)) {
    // An empty chunk tells Dart the microphone could not be opened.
    PostMessage(window_, kCaptureMessage, session,
                reinterpret_cast<LPARAM>(new CaptureChunk()));
  }
  std::vector<uint8_t> chunk;
  chunk.reserve(kCaptureChunkFrames * 2);
  while (SUCCEEDED(hr) && !capture_stop_) {
    WaitForSingleObject(event, 50);
    UINT32 packet = 0;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) {
        break;
      }
      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        chunk.insert(chunk.end(), frames * 2, 0);
      } else {
        chunk.insert(chunk.end(), data, data + frames * 2);
      }
      capture->ReleaseBuffer(frames);
      if (chunk.size() >= kCaptureChunkFrames * 2) {
        auto* message = new CaptureChunk{std::move(chunk)};
        if (!PostMessage(window_, kCaptureMessage, session,
                         reinterpret_cast<LPARAM>(message))) {
          delete message;
        }
        chunk = {};
        chunk.reserve(kCaptureChunkFrames * 2);
      }
    }
  }
  if (client) client->Stop();
  if (event) CloseHandle(event);
  if (SUCCEEDED(com)) CoUninitialize();
}

void AudioEngine::DeliverCapture(WPARAM session, LPARAM chunk) {
  std::unique_ptr<CaptureChunk> data(reinterpret_cast<CaptureChunk*>(chunk));
  if (static_cast<int>(session) != capture_session_ || !sink_) return;
  if (data->bytes.empty()) {
    sink_->Error("microphone_unavailable", "micDenied");
    return;
  }
  sink_->Success(flutter::EncodableValue(std::move(data->bytes)));
}
