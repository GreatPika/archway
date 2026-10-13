# Maintainer-only build of our owned source with preinstalled official tools.
# No downloads, project code execution, toolchain installation, or discovery
# through the inspected repository. Pins match the recorded Windows probe.
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (![Environment]::Is64BitProcess -or $env:OS -ne 'Windows_NT' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
  throw 'The Windows native bridge requires a Windows x64 build process.'
}
$root = Split-Path -Parent $PSScriptRoot
$out = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) }
       else { Join-Path $root 'native/windows-x64' }
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
if (!(Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Installed vswhere is missing.' }
$install = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$install) { throw 'Installed Visual Studio x64 tools are missing.' }
$msvc = Join-Path $install 'VC/Tools/MSVC/14.44.35207'
$sdk = "${env:ProgramFiles(x86)}/Windows Kits/10"
$sdkVersion = '10.0.26100.0'
$bin = Join-Path $msvc 'bin/Hostx64/x64'
$compiler = Join-Path $bin 'cl.exe'
$includes = @("$msvc/include", "$sdk/Include/$sdkVersion/ucrt",
  "$sdk/Include/$sdkVersion/shared", "$sdk/Include/$sdkVersion/um")
$libs = @("$msvc/lib/x64", "$sdk/Lib/$sdkVersion/ucrt/x64", "$sdk/Lib/$sdkVersion/um/x64")
foreach ($path in @($compiler, "$bin/link.exe", "$bin/dumpbin.exe") + $includes + $libs) {
  if (!(Test-Path -LiteralPath $path)) { throw "Pinned installed build input is missing: $path" }
}
Write-Output "Compiler: $compiler version=$((Get-Item -LiteralPath $compiler).VersionInfo.FileVersion)"
Write-Output "Windows SDK: $sdkVersion"
# Do not accept ambient compiler/linker option injection. Restore the caller's
# process environment after this fixed invocation, including on build failure.
$saved = @{}
foreach ($key in @('PATH', 'INCLUDE', 'LIB', 'CL', '_CL_', 'LINK', '_LINK_')) {
  $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
try {
  $env:PATH = "$bin;$env:PATH"
  $env:INCLUDE = $includes -join ';'
  $env:LIB = $libs -join ';'
  $env:CL = $null; $env:_CL_ = $null; $env:LINK = $null; $env:_LINK_ = $null
  New-Item -ItemType Directory -Force $out | Out-Null
  & $compiler /nologo /std:c11 /O2 /W4 /WX /MT /LD /TC `
    "$root/native/windows_io.c" "/Fo$out/windows_io.obj" "/Fe$out/archway_io.dll" `
    /link /MACHINE:X64 /DYNAMICBASE /NXCOMPAT /INCREMENTAL:NO `
    "/IMPLIB:$out/archway_io.lib" ntdll.lib kernel32.lib
  if ($LASTEXITCODE -ne 0) { throw "Native bridge compilation failed: $LASTEXITCODE" }
  if (!(Test-Path -LiteralPath "$out/archway_io.dll" -PathType Leaf)) {
    throw 'Native compiler did not produce the canonical bridge.'
  }
  $dependencies = & "$bin/dumpbin.exe" /DEPENDENTS "$out/archway_io.dll"
  if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect native bridge dependencies.' }
  $dependencies | Write-Output
  if (($dependencies -join "`n") -match '(?i)(vcruntime|msvcp|ucrtbase|api-ms-win-crt)[^\s]*\.dll') {
    throw 'Unexpected dynamic CRT dependency in the statically linked bridge.'
  }
} finally {
  foreach ($key in $saved.Keys) {
    [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
  }
}
