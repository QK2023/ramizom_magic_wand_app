#ifndef RUNNER_AUDIO_DECODER_H_
#define RUNNER_AUDIO_DECODER_H_

#include <cstdint>
#include <string>
#include <vector>

// Decodes a whole compressed audio file (MP3, AAC, FLAC, Opus/Ogg where the
// system has a decoder, WAV...) with Media Foundation into 16-bit mono PCM,
// the form the audio engine plays. Speech APIs answer in many formats.
bool DecodeAudio(const std::vector<uint8_t>& encoded,
                 std::vector<int16_t>* samples, int* sample_rate,
                 std::string* error);

#endif  // RUNNER_AUDIO_DECODER_H_
