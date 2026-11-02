# CI-only installation of the reviewed official SDK, never run by Archway.
param([Parameter(Mandatory=$true)][string]$Target)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$pins = @{
  'linux-x64' = 'ea864bc64df30a6b8bdf30b2e32550f7717d9a890de8f40293aeabb924fe232b'
  'macos-arm64' = '9dfe7d6f2558816c2a978aff6c80e8a4509c6cb726c0702a616c64d286f60e88'
  'windows-x64' = 'aed8e4a8932ce8fa18ea32f990e43b4a1c9390a4c73777ab6fdf77fc9f4524d1'
}
if (!$pins.ContainsKey($Target)) { throw "Unsupported SDK target: $Target" }
$archive = Join-Path $env:RUNNER_TEMP "dartsdk-$Target.zip"
$destination = Join-Path $env:RUNNER_TEMP 'archway-dart'
Invoke-WebRequest "https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.5/sdk/dartsdk-$Target-release.zip" -OutFile $archive
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
