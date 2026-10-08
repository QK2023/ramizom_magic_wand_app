#include "audio_decoder.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <wrl/client.h>

#include <algorithm>

using Microsoft::WRL::ComPtr;

namespace {

bool Decode(const std::vector<uint8_t>& encoded, std::vector<int16_t>* samples,
            int* sample_rate, std::string* error) {
  ComPtr<IStream> memory;
  memory.Attach(SHCreateMemStream(encoded.data(),
                                  static_cast<UINT>(encoded.size())));
  ComPtr<IMFByteStream> stream;
  ComPtr<IMFSourceReader> reader;
  if (!memory || FAILED(MFCreateMFByteStreamOnStream(memory.Get(), &stream)) ||
      FAILED(MFCreateSourceReaderFromByteStream(stream.Get(), nullptr,
                                                &reader))) {
    *error = "The speech audio format is not supported.";
    return false;
  }
  const DWORD audio = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(audio, TRUE);
  // Ask the decoder for 16-bit PCM; channels and rate stay as encoded.
  ComPtr<IMFMediaType> wanted;
  MFCreateMediaType(&wanted);
  wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  wanted->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  wanted->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  ComPtr<IMFMediaType> actual;
  if (FAILED(reader->SetCurrentMediaType(audio, nullptr, wanted.Get())) ||
      FAILED(reader->GetCurrentMediaType(audio, &actual))) {
    *error = "The speech audio could not be decoded.";
    return false;
  }
  UINT32 channels = 0, rate = 0;
  actual->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);
  actual->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
  if (channels == 0 || rate == 0) {
    *error = "The speech audio has no sound.";
    return false;
  }
  samples->clear();
  while (true) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio, 0, nullptr, &flags, nullptr,
                                  &sample))) {
      break;
    }
    if (sample) {
      ComPtr<IMFMediaBuffer> buffer;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
        BYTE* data = nullptr;
        DWORD length = 0;
        if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
          const auto* pcm = reinterpret_cast<const int16_t*>(data);
          const size_t frames = length / 2 / channels;
          // Speech is mono: average the channels.
          for (size_t f = 0; f < frames; ++f) {
            int sum = 0;
            for (UINT32 c = 0; c < channels; ++c) sum += pcm[f * channels + c];
            samples->push_back(static_cast<int16_t>(sum / static_cast<int>(channels)));
          }
          buffer->Unlock();
        }
      }
    }
    if (flags & (MF_SOURCE_READERF_ENDOFSTREAM | MF_SOURCE_READERF_ERROR)) {
      break;
    }
  }
  *sample_rate = static_cast<int>(rate);
  if (samples->empty()) {
    *error = "The speech audio has no sound.";
    return false;
  }
  return true;
}

}  // namespace

bool DecodeAudio(const std::vector<uint8_t>& encoded,
                 std::vector<int16_t>* samples, int* sample_rate,
                 std::string* error) {
  if (encoded.empty()) {
    *error = "The speech API returned no audio.";
    return false;
  }
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool ok = false;
  if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    ok = Decode(encoded, samples, sample_rate, error);
    MFShutdown();
  } else {
    *error = "Media Foundation is unavailable.";
  }
  if (SUCCEEDED(com)) CoUninitialize();
  return ok;
}
