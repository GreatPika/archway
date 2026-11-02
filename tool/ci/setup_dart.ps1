# CI-only installation of the reviewed official SDK, never run by Archway.
param([Parameter(Mandatory=$true)][string]$Target)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$pins = @{
  'linux-x64' = '549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7'
  'macos-arm64' = 'c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc'
  'windows-x64' = '30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e'
}
if (!$pins.ContainsKey($Target)) { throw "Unsupported SDK target: $Target" }
$archive = Join-Path $env:RUNNER_TEMP "dartsdk-$Target.zip"
$destination = Join-Path $env:RUNNER_TEMP 'archway-dart'
Invoke-WebRequest "https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/dartsdk-$Target-release.zip" -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pins[$Target]) {
  throw 'Official SDK bytes differ from the reviewed SHA-256 pin.'
}
if ($IsWindows) {
  Expand-Archive -LiteralPath $archive -DestinationPath $destination
} else {
  New-Item -ItemType Directory -Force $destination | Out-Null
  & unzip -q $archive -d $destination
  if ($LASTEXITCODE -ne 0) { throw 'SDK extraction failed.' }
}
$sdk = Join-Path $destination 'dart-sdk'
$bin = Join-Path $sdk 'bin'
$dart = Join-Path $bin $(if ($IsWindows) { 'dart.exe' } else { 'dart' })
& $dart --version
if ($LASTEXITCODE -ne 0) { throw 'Pinned SDK cannot execute on this host.' }
$bin | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
"DART_SDK=$sdk" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"PUB_CACHE=$(Join-Path $env:RUNNER_TEMP 'archway-pub-cache')" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
