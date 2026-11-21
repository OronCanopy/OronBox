param(
  [switch]$Dev,
  [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "..")
$ReleaseDir = Join-Path $ProjectRoot "build/release"
$AppName = "oronbox"

function Require-Command($Name) {
  if (!(Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Get-PubspecVersion {
  $Pubspec = Join-Path $ProjectRoot "pubspec.yaml"
  $Line = Select-String -Path $Pubspec -Pattern '^version:\s*([^+]+)(?:\+(\d+))?' | Select-Object -First 1
  if (!$Line) {
    throw "Could not read version from pubspec.yaml"
  }
  return @{
    BaseVersion = $Line.Matches[0].Groups[1].Value.Trim()
    BuildNumber = if ($Line.Matches[0].Groups[2].Success) { $Line.Matches[0].Groups[2].Value } else { "1" }
  }
}

function Find-WindowsBundle {
  param(
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [Parameter(Mandatory = $true)][string]$AppName
  )

  if (!(Test-Path $BuildRoot)) {
    return $null
  }

  $Executables = @(
    Get-ChildItem -Path $BuildRoot -Filter "$AppName.exe" -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Directory.Name -ieq "Release" } |
      Sort-Object LastWriteTime -Descending
  )
  if ($Executables.Count -gt 0) {
    return $Executables[0].Directory.FullName
  }

  $OtherExecutables = @(
    Get-ChildItem -Path $BuildRoot -Filter "*.exe" -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Directory.Name -ieq "Release" } |
      Sort-Object FullName
  )
  if ($OtherExecutables.Count -gt 0) {
    Write-Host "[ERROR] Windows Release bundle contains executables, but none is named $AppName.exe:"
    $OtherExecutables | ForEach-Object { Write-Host "  $($_.FullName)" }
  }
  return $null
}

Require-Command "git"
Require-Command "flutter"
Require-Command "python"

$VersionInfo = Get-PubspecVersion
$GitHash = (git -C $ProjectRoot rev-parse --short=7 HEAD 2>$null)
if ([string]::IsNullOrWhiteSpace($GitHash)) {
  $GitHash = "nogit"
}
$BuildUser = [Environment]::UserName

git -C $ProjectRoot update-index --refresh *> $null
$Dirty = $false
git -C $ProjectRoot diff-index --quiet HEAD -- *> $null
if ($LASTEXITCODE -ne 0) {
  $Dirty = $true
}
$Untracked = git -C $ProjectRoot ls-files --others --exclude-standard
if ($Untracked) {
  $Dirty = $true
}

$Version = $VersionInfo.BaseVersion
if ($Dev) {
  $Version = "$($VersionInfo.BaseVersion)-dev.$GitHash"
  if ($Dirty) {
    $Version = "$Version.dirty"
  }
} elseif ($Dirty) {
  throw "Git working tree is dirty. Commit or stash changes first, or use -Dev."
}

$FullGitHash = (git -C $ProjectRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0) { throw "Could not read the full Git commit" }
& python (Join-Path $ScriptDir "prepare_build_integrity.py") --project-root $ProjectRoot --version $Version --commit $FullGitHash
if ($LASTEXITCODE -ne 0) { throw "Client attestation configuration failed" }
$IntegrityDefines = Join-Path $ProjectRoot "build/integrity_defines.json"

New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null

Write-Host "[INFO] Building Windows release package for version $Version"
flutter build windows --release --obfuscate --split-debug-info=symbols\windows --build-name=$Version --build-number=$($VersionInfo.BuildNumber) --dart-define=APP_VERSION=$Version --dart-define=GIT_COMMIT_HASH=$GitHash --dart-define=BUILD_USER=$BuildUser "--dart-define-from-file=$IntegrityDefines"
if ($LASTEXITCODE -ne 0) {
  throw "Flutter Windows build failed with exit code $LASTEXITCODE"
}

$WindowsBuildRoot = Join-Path $ProjectRoot "build/windows"
$BundleDir = Find-WindowsBundle -BuildRoot $WindowsBuildRoot -AppName $AppName
if ([string]::IsNullOrWhiteSpace($BundleDir)) {
  throw "Windows build output not found under $WindowsBuildRoot. Expected $AppName.exe in a Release bundle."
}
Write-Host "[INFO] Using Windows bundle: $BundleDir"

$Output = Join-Path $ReleaseDir "$AppName-$Version-windows-amd64.zip"
if (Test-Path $Output) {
  Remove-Item -Force $Output
}
Compress-Archive -Path (Join-Path $BundleDir "*") -DestinationPath $Output -Force
Write-Host "[INFO] Produced $Output"

$SymbolsDir = Join-Path $ProjectRoot "symbols/windows"
$SymbolsOutput = Join-Path $ReleaseDir "$AppName-$Version-windows-amd64.symbols.zip"
if (Test-Path $SymbolsDir) {
  if (Test-Path $SymbolsOutput) {
    Remove-Item -Force $SymbolsOutput
  }
  Compress-Archive -Path (Join-Path $SymbolsDir "*") -DestinationPath $SymbolsOutput -Force
  Write-Host "[INFO] Produced $SymbolsOutput"
} else {
  Write-Host "[WARN] Symbols directory not found; skipped symbols package: $SymbolsDir"
}

if (!$SkipInstaller) {
  $Iscc = $null
  foreach ($candidate in @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  )) {
    if (Test-Path $candidate) {
      $Iscc = $candidate
      break
    }
  }
  if (!$Iscc) {
    throw "Inno Setup 6 (ISCC.exe) not found. Install it (choco install innosetup) or pass -SkipInstaller."
  }
  $IssFile = Join-Path $ScriptDir "packaging/windows/oronbox.iss"
  & $Iscc $IssFile "/DMyAppVersion=$Version" "/DBundleDir=$BundleDir"
  if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
  }
  Write-Host "[INFO] Produced Windows installer in $ReleaseDir"
}

Write-Host "[INFO] Windows build complete"
