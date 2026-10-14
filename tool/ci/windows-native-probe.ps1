param([Parameter(Mandatory)][ValidateSet('toolchain', 'setup', 'policy', 'init', 'residual', 'nested-export', 'overwrite', 'bom-alias', 'absolute-alias', 'junction', 'aot-assets', 'adapter-source', 'assembly-init')][string]$Phase,
      [string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($ArtifactDirectory -and $Phase -ne 'assembly-init') {
  throw 'ArtifactDirectory is only supported by assembly-init.'
}
$evidence = Join-Path $env:RUNNER_TEMP 'archway-windows-evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$dart = Join-Path $env:RUNNER_TEMP 'archway-dart/dart-sdk/bin/dart.exe'
Start-Transcript -Path "$evidence/$Phase.log" | Out-Null
try {
  if ($Phase -eq 'toolchain') {
    # Inspect only preinstalled, official image tools. Missing tools do not turn
    # setup into a fake semantic red; implementation feasibility stays unproven.
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    if (Test-Path $vswhere) {
      $install = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
      if ($LASTEXITCODE -ne 0) { throw 'Installed vswhere failed.' }
      if ($install) {
        Write-Output "Visual Studio: $install"
        Get-ChildItem "$install/VC/Tools/MSVC/*/bin/Hostx64/x64/cl.exe" |
          ForEach-Object { Write-Output "MSVC: $($_.FullName) version=$($_.VersionInfo.FileVersion)" }
      } else { Write-Output 'No installed Visual Studio x64 C tools found.' }
    } else { Write-Output 'No installed vswhere found.' }
    $sdk = "${env:ProgramFiles(x86)}/Windows Kits/10/Include"
    if (Test-Path $sdk) {
      Get-ChildItem $sdk -Directory | ForEach-Object {
        Write-Output "Windows SDK: $($_.Name); windows.h=$(Test-Path "$($_.FullName)/um/windows.h"); winternl.h=$(Test-Path "$($_.FullName)/um/winternl.h")"
      }
    } else { Write-Output 'No installed Windows SDK headers found.' }
  } elseif ($Phase -eq 'setup') {
    $name = 'dartsdk-windows-x64-release.zip'
    $url = "https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/$name"
    $zip = Join-Path $env:RUNNER_TEMP $name
    Invoke-WebRequest "$url.sha256sum" -OutFile "$zip.sha256sum"
    $checksum = (Get-Content "$zip.sha256sum" -Raw).Trim()
    if ($checksum -notmatch '^([0-9a-fA-F]{64})\s+\*?dartsdk-windows-x64-release\.zip$') {
      throw 'Invalid official Dart checksum record.'
    }
    # Official release checksum retrieved independently during configuration review.
    $expected = '30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e'
    if ($Matches[1].ToLowerInvariant() -ne $expected) { throw 'Official checksum changed from the reviewed pin.' }
    Invoke-WebRequest $url -OutFile $zip
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "url=$url`nexpected_sha256=$expected`nactual_sha256=$actual" | Set-Content "$evidence/dart-integrity.txt"
    if ($actual -ne $expected) { throw 'Dart SDK checksum mismatch; refusing execution.' }
    Expand-Archive -Path $zip -DestinationPath (Join-Path $env:RUNNER_TEMP 'archway-dart')
    $version = & $dart --suppress-analytics --version 2>&1
    if ($LASTEXITCODE -ne 0 -or "$version" -notmatch 'Dart SDK version: 3\.13\.3 .*"windows_x64"') {
      throw "Unexpected Dart runtime: $version"
    }
    Write-Output $version
    & $dart --suppress-analytics pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency preparation failed; NOT a semantic red.' }
    git diff --exit-code -- pubspec.lock
    if ($LASTEXITCODE -ne 0) { throw 'Dependency lock changed; refusing probe.' }
    # Future backend owner supplies this fixed build entry point. Absent today:
    # allow the real CLI to expose the unsupported-platform first red.
    if (Test-Path './tool/build_native_windows.ps1') {
      $global:LASTEXITCODE = 0
      & ./tool/build_native_windows.ps1
      if ($LASTEXITCODE -ne 0) { throw 'Native build failed; NOT a semantic red.' }
    } else { Write-Output 'Windows backend build entry point absent; proceeding to real CLI probe.' }
  } elseif ($Phase -eq 'policy') {
    & $dart --suppress-analytics test test/plan_test.dart --name 'loads exact empty policy bytes with counts and EMPTY_PLAN warning' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Policy-only baseline failed; init gate not reached.' }
    # Only the public root-selection regression, using the already prepared SDK.
    # A load/setup failure is not a Windows root-classification semantic red.
    & $dart --suppress-analytics test test/cli_test.dart --plain-name 'missing or nondirectory selected roots are usage errors with complete JSON' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Root classification failed; require ROOT_CLASSIFICATION_FIXTURE_READY for the failing root and a CLI assertion before classifying a semantic red.' }
    'Policy and selected-root source baselines passed.' | Set-Content "$evidence/policy-passed.txt"
  } elseif ($Phase -eq 'init') {
    if (!(Test-Path "$evidence/policy-passed.txt")) { throw 'Policy baseline evidence missing.' }
    # The test creates its root beneath this exact base, not system TEMP.
    $device = [IO.Path]::GetPathRoot($env:RUNNER_TEMP).TrimEnd('\')
    $volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$device'"
    [ordered]@{ test_root_base = $env:RUNNER_TEMP; device = $volume.DeviceID;
      filesystem = $volume.FileSystem } | ConvertTo-Json |
      Tee-Object "$evidence/test-volume.json"
    if ($volume.FileSystem -ne 'NTFS') { throw 'CLI native probe requires its actual root on NTFS.' }
    & $dart --suppress-analytics test test/windows_native_probe_test.dart --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'CLI init assertion failed; inspect test output for semantic versus load/setup failure.' }
    'Fresh-root native init passed.' | Set-Content "$evidence/init-passed.txt"
  } elseif ($Phase -eq 'residual') {
    if (!(Test-Path "$evidence/init-passed.txt")) { throw 'Native init control evidence missing.' }
    # Reuse the contractual Bootstrap regression, on the same attested root base.
    & $dart --suppress-analytics test test/bootstrap_test.dart --name 'already removed created paths are not reported as residual files' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Bootstrap missing-residual assertion failed; inspect outcome and diagnostics.' }
    'Missing-residual native observation passed.' | Set-Content "$evidence/residual-passed.txt"
  } elseif ($Phase -eq 'nested-export') {
    if (!(Test-Path "$evidence/residual-passed.txt")) { throw 'Native residual control evidence missing.' }
    & $dart --suppress-analytics test test/catalogue_export_test.dart --name 'file export exclusively creates output through existing child directories' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Nested export assertion failed; inspect CLI outcome and diagnostics.' }
    'Nested native export passed.' | Set-Content "$evidence/nested-passed.txt"
  } elseif ($Phase -eq 'overwrite') {
    if (!(Test-Path "$evidence/nested-passed.txt")) { throw 'Native nested-export control evidence missing.' }
    & $dart --suppress-analytics test test/catalogue_export_test.dart --plain-name 'file export exclusively creates output and requires explicit overwrite' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Explicit overwrite assertion failed; inspect CLI outcome and diagnostics.' }
    'Explicit native overwrite passed.' | Set-Content "$evidence/overwrite-passed.txt"
  } elseif ($Phase -eq 'bom-alias') {
    if (!(Test-Path "$evidence/overwrite-passed.txt")) { throw 'Native overwrite control evidence missing.' }
    & $dart --suppress-analytics test test/physical_paths_test.dart --plain-name 'root canonicalization preserves a literal leading BOM in a link target' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'BOM alias assertion failed; require BOM_ALIAS_FIXTURE_READY before classifying a semantic red.' }
    'Relative BOM alias passed.' | Set-Content "$evidence/bom-alias-passed.txt"
  } elseif ($Phase -eq 'absolute-alias') {
    if (!(Test-Path "$evidence/bom-alias-passed.txt")) { throw 'Native BOM-alias control evidence missing.' }
    & $dart --suppress-analytics test test/physical_paths_test.dart --plain-name 'Windows root canonicalization follows an absolute directory symbolic link' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Absolute alias assertion failed; require ABSOLUTE_ALIAS_FIXTURE_READY before classifying a semantic red.' }
    'Absolute directory symlink passed.' | Set-Content "$evidence/absolute-alias-passed.txt"
  } elseif ($Phase -eq 'junction') {
    if (!(Test-Path "$evidence/absolute-alias-passed.txt")) { throw 'Native absolute-alias control evidence missing.' }
    & $dart --suppress-analytics test test/physical_paths_test.dart --plain-name 'Windows root canonicalization follows a local directory junction' --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Junction assertion failed; require JUNCTION_FIXTURE_READY before classifying a semantic red.' }
    'Local directory junction passed.' | Set-Content "$evidence/junction-passed.txt"
  } elseif ($Phase -eq 'aot-assets') {
    if (!(Test-Path "$evidence/junction-passed.txt")) { throw 'Native source controls must pass before AOT setup.' }
    $name = 'node-v24.21.0-win-x64.zip'
    $url = "https://nodejs.org/dist/v24.21.0/$name"
    $zip = Join-Path $env:RUNNER_TEMP $name
    # Official SHASUMS256.txt retrieved independently during configuration review.
    $expected = '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541'
    Invoke-WebRequest 'https://nodejs.org/dist/v24.21.0/SHASUMS256.txt' -OutFile "$zip.sha256sums"
    $record = @(Get-Content "$zip.sha256sums" | Where-Object { $_ -match '^[0-9a-f]{64}\s+node-v24\.21\.0-win-x64\.zip$' })
    if ($record.Count -ne 1 -or ($record[0] -split '\s+')[0] -ne $expected) { throw 'Official Node checksum differs from reviewed pin.' }
    Invoke-WebRequest $url -OutFile $zip
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "url=$url`nexpected_sha256=$expected`nactual_sha256=$actual" | Set-Content "$evidence/node-integrity.txt"
    if ($actual -ne $expected) { throw 'Node checksum mismatch; refusing execution.' }
    $nodeRoot = Join-Path $env:RUNNER_TEMP 'archway-node'
    Expand-Archive -Path $zip -DestinationPath $nodeRoot
    $nodeBin = Join-Path $nodeRoot 'node-v24.21.0-win-x64'
    $env:PATH = "$nodeBin;$env:PATH"
    & "$nodeBin/node.exe" -e 'const a = require("node:assert/strict"); a.equal(process.version, "v24.21.0"); a.equal(process.platform, "win32"); a.equal(process.arch, "x64"); console.log(process.version, process.platform, process.arch)'
    if ($LASTEXITCODE -ne 0) { throw 'Unexpected pinned Node runtime.' }
    & "$nodeBin/npm.cmd" --version
    if ($LASTEXITCODE -ne 0) { throw 'Pinned npm unavailable.' }
    # Fixed Git for Windows installation, never a PATH-selected WSL bash shim.
    $bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
    if (!(Test-Path $bash -PathType Leaf)) { throw 'Installed Git for Windows bash missing.' }
    $bashHost = & $bash -c 'uname -s'
    if ($LASTEXITCODE -ne 0 -or "$bashHost" -notmatch '^MINGW(32|64)_NT-') { throw "Not Git for Windows bash: $bashHost" }
    Write-Output "Git Bash: $bash ($bashHost)"
    # Only Archway's own locked packages; prepare_typescript disables lifecycle scripts.
    $bashNode = & $bash -c 'node -p process.execPath'
    if ($LASTEXITCODE -ne 0 -or $bashNode -ne (Join-Path $nodeBin 'node.exe')) { throw 'Git Bash did not resolve the pinned Node first.' }
    $bashNpm = & $bash -c 'cygpath -w "$(command -v npm)"'
    if ($LASTEXITCODE -ne 0 -or $bashNpm -ne (Join-Path $nodeBin 'npm')) { throw 'Git Bash did not resolve the pinned npm first.' }
    & $bash tool/prepare_typescript.sh
    if ($LASTEXITCODE -ne 0) { throw 'Owned AOT asset preparation failed; NOT a semantic red.' }
    foreach ($package in @(@('typescript', '5.9.3'), @('yaml', '2.8.1'))) {
      $manifest = Get-Content "assets/typescript/vendor/$($package[0])/package.json" -Raw | ConvertFrom-Json
      if ($manifest.version -ne $package[1]) { throw "Unexpected owned vendor version: $($package[0])" }
      Write-Output "Prepared owned vendor: $($package[0]) $($manifest.version)"
    }
    git diff --exit-code -- assets/typescript/package-lock.json
    if ($LASTEXITCODE -ne 0) { throw 'Owned asset lock changed; refusing AOT probe.' }
    Get-FileHash assets/typescript/package-lock.json -Algorithm SHA256
    'Owned locked AOT assets prepared.' | Set-Content "$evidence/aot-assets-passed.txt"
  } elseif ($Phase -eq 'adapter-source') {
    if (!(Test-Path "$evidence/aot-assets-passed.txt")) { throw 'Owned adapter asset preparation evidence missing.' }
    $savedPath = $env:PATH
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    try {
      $dartBin = Split-Path -Parent $dart
      $nodeBin = Join-Path $env:RUNNER_TEMP 'archway-node/node-v24.21.0-win-x64'
      $node = Join-Path $nodeBin 'node.exe'
      if (![IO.Path]::IsPathFullyQualified($dart) -or ![IO.Path]::IsPathFullyQualified($node)) {
        throw 'Adapter runtime paths must be absolute.'
      }
      if (!(Test-Path $dart -PathType Leaf) -or !(Test-Path $node -PathType Leaf)) {
        throw 'Checksum-verified adapter runtimes missing; no hosted fallback.'
      }
      # Child compiler adapters discover executables through PATH, not $dart.
      $env:PATH = "$dartBin;$nodeBin;$savedPath"
      foreach ($runtime in @(@('dart', $dart), @('node', $node))) {
        $resolved = (Get-Command $runtime[0] -CommandType Application | Select-Object -First 1).Source
        Write-Output "Adapter runtime: $resolved"
        if ($resolved -ne $runtime[1]) { throw "Adapter runtime precedence mismatch: $($runtime[0])" }
      }
      & $dart --version
      if ($LASTEXITCODE -ne 0) { throw 'Pinned Dart unavailable.' }
      & $node --version
      if ($LASTEXITCODE -ne 0) { throw 'Pinned Node unavailable.' }
      # Existing fixtures use Directory.systemTemp. Scope both Windows temp
      # variables to the same inspected base rather than assume runner TEMP.
      $testTemp = Join-Path $env:RUNNER_TEMP 'archway-adapter-source'
      New-Item -ItemType Directory -Force $testTemp | Out-Null
      $env:TEMP = $testTemp
      $env:TMP = $testTemp
      $actualTemp = [IO.Path]::GetTempPath()
      $device = [IO.Path]::GetPathRoot($actualTemp).TrimEnd('\')
      $volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$device'"
      [ordered]@{ test_root_base = $actualTemp; device = $volume.DeviceID;
        filesystem = $volume.FileSystem; commit = $env:GITHUB_SHA } |
        ConvertTo-Json | Tee-Object "$evidence/adapter-source-volume.json"
      if ($volume.FileSystem -ne 'NTFS') { throw 'Adapter source fixtures require their actual temp base on NTFS.' }
      & $dart --suppress-analytics run tool/ci/windows_adapter_link_readiness.dart
      if ($LASTEXITCODE -ne 0) { throw 'Relative file-link readiness failed; adapter gate not reached.' }
      $files = @('test/inspection_test.dart', 'test/typescript_references_test.dart',
        'test/typescript_projects_test.dart', 'test/dart_inspection_test.dart',
        'test/input_mutations_test.dart')
      Write-Output "Selected files (serial): $($files -join ', ')"
      Write-Output 'No name exclusions. Existing Linux-only unreadable-directory/chmod case skips on Windows.'
      & $dart --suppress-analytics test --concurrency=1 --reporter expanded @files
      if ($LASTEXITCODE -ne 0) { throw 'Adapter source suite failed; inspect setup versus compiler assertions.' }
    } finally {
      $env:PATH = $savedPath
      $env:TEMP = $savedTemp
      $env:TMP = $savedTmp
    }
  } else {
    if (!(Test-Path "$evidence/aot-assets-passed.txt")) { throw 'Owned AOT asset preparation evidence missing.' }
    $arguments = @('--suppress-analytics', 'run', 'tool/ci/native_assembly_init_probe.dart', '--init-only', '--dart', $dart)
    if ($ArtifactDirectory) { $arguments += @('--artifact-directory', $ArtifactDirectory) }
    & $dart @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Maintainer assembly/init assertion failed; inspect missing assembler versus setup or CLI result.' }
  }
} catch {
  Write-Output "Phase $Phase failed: $($_.Exception.Message)"
  throw
} finally {
  Stop-Transcript | Out-Null
}
