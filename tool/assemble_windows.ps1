# Maintainer-only assembly of owned sources and already prepared assets.
# No downloads, dependency installs, project hooks, or external Node execution.
param(
  [Parameter(Mandatory)][string]$Output,
  [Parameter(Mandatory)][string]$Dart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
  throw 'Windows assembly requires a native Windows x64 process.'
}

function Get-ExistingAttributes([string]$Path) {
  try { return [IO.File]::GetAttributes($Path) }
  catch [IO.FileNotFoundException] { return $null }
  catch [IO.DirectoryNotFoundException] { return $null }
}

function Assert-NoReparsePath([string]$Path, [switch]$AllowMissing) {
  $cursor = [IO.Path]::GetFullPath($Path)
  while ($cursor) {
    $attributes = Get-ExistingAttributes $cursor
    if ($null -eq $attributes) {
      if (!$AllowMissing) { throw "Required assembly input is missing: $cursor" }
    } elseif (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Assembly path is a reparse point: $cursor"
    }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
  }
}

function Copy-OwnedTree([string]$Source, [string]$Destination) {
  $attributes = [IO.File]::GetAttributes($Source)
  if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Owned asset is a reparse point: $Source"
  }
  if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Source)) {
      Copy-OwnedTree $entry ([IO.Path]::Combine($Destination, [IO.Path]::GetFileName($entry)))
    }
  } else {
    # File.Copy does not interpret wildcards and never overwrites staged files.
    [IO.File]::Copy($Source, $Destination, $false)
  }
}

$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (![IO.Path]::IsPathFullyQualified($Output) -or ![IO.Path]::IsPathFullyQualified($Dart)) {
  throw 'Supply absolute paths for Output and the pinned Dart executable.'
}
$outputPath = [IO.Path]::GetFullPath($Output)
$dartPath = [IO.Path]::GetFullPath($Dart)
Assert-NoReparsePath $root
Assert-NoReparsePath $outputPath -AllowMissing
if ($null -ne (Get-ExistingAttributes $outputPath)) {
  throw "Assembly output already exists: $outputPath"
}
Assert-NoReparsePath $dartPath
if (![IO.File]::Exists($dartPath)) { throw 'The supplied Dart executable is not a file.' }
$version = & $dartPath --suppress-analytics --version 2>&1
if ($LASTEXITCODE -ne 0 -or "$version" -notmatch 'Dart SDK version: 3\.13\.3 .*"windows_x64"') {
  throw "Unexpected Dart compiler: $version"
}
Write-Output "Dart compiler: $dartPath; $version"
$assets = [IO.Path]::GetFullPath((Join-Path $root 'assets/typescript'))
if ($outputPath.StartsWith($assets + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Assembly output cannot be inside the owned source asset tree.'
}
$builder = Join-Path $root 'tool/build_native_windows.ps1'
$entrypoint = Join-Path $root 'bin/archway.dart'
Assert-NoReparsePath $builder
Assert-NoReparsePath $entrypoint
Assert-NoReparsePath $assets
foreach ($package in @(@('typescript', '5.9.3'), @('yaml', '2.8.1'))) {
  $manifestPath = Join-Path $assets "vendor/$($package[0])/package.json"
  Assert-NoReparsePath $manifestPath
  $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
  if ($manifest.version -ne $package[1]) { throw "Unexpected owned vendor: $($package[0])" }
}
foreach ($relative in @('vendor/typescript/lib/typescript.js', 'vendor/yaml/dist/index.js')) {
  $inputPath = Join-Path $assets $relative
  Assert-NoReparsePath $inputPath
  if (![IO.File]::Exists($inputPath)) { throw "Prepared owned asset is missing: $relative" }
}

$parent = [IO.Path]::GetDirectoryName($outputPath)
[IO.Directory]::CreateDirectory($parent) | Out-Null
Assert-NoReparsePath $parent
$stage = Join-Path $parent ('.archway-assembly-' + [Guid]::NewGuid().ToString('N'))
$scratch = Join-Path $parent ('.archway-native-build-' + [Guid]::NewGuid().ToString('N'))
$stageOwned = $false
$scratchOwned = $false
$location = Get-Location
try {
  foreach ($path in @($stage, $scratch)) {
    if ($null -ne (Get-ExistingAttributes $path)) { throw "Assembly scratch already exists: $path" }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    if ($path -eq $stage) { $stageOwned = $true } else { $scratchOwned = $true }
    Assert-NoReparsePath $path
  }
  $binaryDirectory = Join-Path $stage 'bin/windows-x64'
  $bridgeDirectory = Join-Path $stage 'native/windows-x64'
  $assetDirectory = Join-Path $stage 'assets/typescript'
  foreach ($path in @($binaryDirectory, $bridgeDirectory, $assetDirectory)) {
    [IO.Directory]::CreateDirectory($path) | Out-Null
  }
  foreach ($source in [IO.Directory]::EnumerateFiles($assets)) {
    if ([IO.Path]::GetExtension($source) -in @('.cjs', '.json', '.md')) {
      Copy-OwnedTree $source (Join-Path $assetDirectory ([IO.Path]::GetFileName($source)))
    }
  }
  foreach ($directory in @('licenses', 'vendor')) {
    Copy-OwnedTree (Join-Path $assets $directory) (Join-Path $assetDirectory $directory)
  }
  # The builder pins MSVC/SDK, clears option injection, restores its environment,
  # and verifies the static CRT. Never reuse the repository's previous DLL.
  & $builder -OutputDirectory $scratch
  if ($LASTEXITCODE -ne 0) { throw 'Native bridge builder failed.' }
  $bridge = Join-Path $scratch 'archway_io.dll'
  Assert-NoReparsePath $bridge
  [IO.File]::Copy($bridge, (Join-Path $bridgeDirectory 'archway_io.dll'), $false)
  Set-Location -LiteralPath $root
  $binary = Join-Path $binaryDirectory 'archway.exe'
  & $dartPath --suppress-analytics compile exe '-Darchway.native=true' `
    $entrypoint -o $binary
  if ($LASTEXITCODE -ne 0) { throw "Native AOT compilation failed: $LASTEXITCODE" }
  Assert-NoReparsePath $binary
  if (![IO.File]::Exists($binary)) { throw 'Dart did not produce the native executable.' }
  # Rename within the same parent/volume. Directory.Move refuses an existing
  # destination; no force, replacement, or fallback copy is permitted.
  Assert-NoReparsePath $outputPath -AllowMissing
  [IO.Directory]::Move($stage, $outputPath)
  $stageOwned = $false
  Write-Output "Assembled Windows x64 installation: $outputPath"
} finally {
  Set-Location -LiteralPath $location.Path
  foreach ($owned in @(@($scratch, $scratchOwned), @($stage, $stageOwned))) {
    if ($owned[1]) {
      Assert-NoReparsePath $owned[0]
      Remove-Item -LiteralPath $owned[0] -Recurse -Force
    }
  }
}
