param(
  [string]$LlamaServerRoot = 'C:\Users\Administrator\Desktop\llama-server-ohos'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$target = Join-Path $repoRoot 'apps/compute-node/entry/src/main/cpp/llama'
$libraryTarget = Join-Path $target 'arm64-v8a'
$bundleLibraryTarget = Join-Path $repoRoot 'apps/compute-node/entry/libs/arm64-v8a'
$librarySource = Join-Path $LlamaServerRoot 'entry/build/default/intermediates/libs/default/arm64-v8a'
$llamaSource = Join-Path $LlamaServerRoot 'entry/src/main/cpp/llama.cpp-gitee'
$openmpSource = Join-Path $LlamaServerRoot 'entry/src/main/cpp/openmp/arm64-v8a/lib/libomp.so'

if (-not (Test-Path -LiteralPath $librarySource -PathType Container)) {
  throw "llama runtime directory not found: $librarySource. Build llama-server-ohos first."
}
if (-not (Test-Path -LiteralPath (Join-Path $llamaSource 'include/llama.h') -PathType Leaf)) {
  throw "llama.cpp headers not found under $llamaSource."
}

New-Item -ItemType Directory -Force -Path $libraryTarget, $bundleLibraryTarget,
  (Join-Path $target 'include/ggml'), (Join-Path $target 'vendor') | Out-Null
$libraries = @(
  'libllama.so', 'libllama.so.0.3.0',
  'libllama-common.so', 'libllama-common.so.0.3.0',
  'libllama-server-impl.so',
  'libmtmd.so', 'libmtmd.so.0.3.0',
  'libggml.so', 'libggml.so.0.22.0',
  'libggml-base.so', 'libggml-base.so.0.22.0',
  'libggml-cpu.so', 'libggml-cpu.so.0.22.0',
  'libggml-rpc.so', 'libggml-rpc.so.0.22.0',
  'libc++_shared.so'
)
foreach ($name in $libraries) {
  Copy-Item -LiteralPath (Join-Path $librarySource $name) -Destination $libraryTarget -Force
  Copy-Item -LiteralPath (Join-Path $librarySource $name) -Destination $bundleLibraryTarget -Force
}
Copy-Item -LiteralPath $openmpSource -Destination $libraryTarget -Force
Copy-Item -LiteralPath $openmpSource -Destination $bundleLibraryTarget -Force
Copy-Item -LiteralPath (Join-Path $llamaSource 'include/llama.h') -Destination (Join-Path $target 'include') -Force
Copy-Item -LiteralPath (Join-Path $llamaSource 'include/llama-cpp.h') -Destination (Join-Path $target 'include') -Force
Copy-Item -Path (Join-Path $llamaSource 'ggml/include/*.h') -Destination (Join-Path $target 'include/ggml') -Force
Copy-Item -LiteralPath (Join-Path $llamaSource 'vendor/nlohmann/json.hpp') -Destination (Join-Path $target 'vendor') -Force
Copy-Item -LiteralPath (Join-Path $llamaSource 'LICENSE') -Destination (Join-Path $target 'LICENSE') -Force

Write-Host "llama.cpp runtime refreshed under $target"
