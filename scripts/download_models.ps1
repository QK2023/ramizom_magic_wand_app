# Downloads the SenseVoice speech-recognition model (about 240 MB) into assets/asr.
# It is too large for a normal GitHub repository, so it is not committed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'assets/asr'
$target = Join-Path $dest 'model.int8.onnx'
if (Test-Path $target) { Write-Host 'model.int8.onnx already present.'; exit 0 }

$name = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17'
$url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$name.tar.bz2"
$tmp = Join-Path ([IO.Path]::GetTempPath()) "$name.tar.bz2"
Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $tmp
tar -xjf $tmp -C ([IO.Path]::GetTempPath()) "$name/model.int8.onnx"
Move-Item (Join-Path ([IO.Path]::GetTempPath()) "$name/model.int8.onnx") $target
Remove-Item $tmp
Write-Host "Saved $target"
