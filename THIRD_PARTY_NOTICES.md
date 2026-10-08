# Third-party notices

The project's own code is MIT-licensed (see [LICENSE](LICENSE)). The following bundled or downloaded assets are covered by their own terms. Dart/Flutter package dependencies are listed in `pubspec.yaml` and carry their own licenses (visible in the app via Flutter's license page).

| Asset | Location | License |
| --- | --- | --- |
| SenseVoice speech model (FunASR / Alibaba Group), int8 ONNX export via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | `assets/asr/model.int8.onnx` (downloaded by `scripts/download_models.ps1`), `tokens.txt` | [FunASR Model License](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE): free to use, copy, modify and share if you attribute the source and keep the model name |
| Silero VAD | `assets/asr/silero_vad.onnx` | MIT, https://github.com/snakers4/silero-vad |
| Caveat font | `assets/fonts/Caveat.ttf` | SIL OFL 1.1, see `assets/fonts/OFL-Caveat.txt` |
| Kalam font | `assets/fonts/Kalam-Regular.ttf` | SIL OFL 1.1, see `assets/fonts/OFL-Kalam.txt` |
| Long Cang font | `assets/fonts/LongCang-Regular.ttf` | SIL OFL 1.1, see `assets/fonts/OFL-LongCang.txt` |
| Microsoft Edge neural voices | online service, not bundled | Microsoft terms apply; unofficial endpoint |
