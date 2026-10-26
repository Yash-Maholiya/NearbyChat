# NearbyChat Flutter helper for Windows.
# 1. Installs git (via winget) and the Flutter stable SDK if they are missing.
# 2. Runs flutter doctor, pub get, analyze and test once, logging to tools\logs\setup.log
# 3. Then waits for requests in tools\runner\inbox and runs ONLY these fixed commands
#    inside nearby_chat\:  pub-get, analyze, test, doctor, devices, build-apk
#    Output goes to tools\runner\out\<request>.log. Close this window to stop it.

$ErrorActionPreference = 'Continue'
$ToolsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root       = Split-Path -Parent $ToolsDir
$AppDir     = Join-Path $Root 'nearby_chat'
$LogDir     = Join-Path $ToolsDir 'logs'
$Inbox      = Join-Path $ToolsDir 'runner\inbox'
$OutDir     = Join-Path $ToolsDir 'runner\out'
$InstallDir = Join-Path $env:USERPROFILE 'dev'
$FlutterBin = Join-Path $InstallDir 'flutter\bin'
New-Item -ItemType Directory -Force -Path $LogDir, $Inbox, $OutDir, $InstallDir | Out-Null
$SetupLog = Join-Path $LogDir 'setup.log'

function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line -ForegroundColor Cyan
  Add-Content -Path $SetupLog -Value $line -Encoding UTF8
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
function Run-Logged($label, $exe, $argList, $logFile) {
  Add-Content -Path $logFile -Value "`n===== $label : $exe $argList =====" -Encoding UTF8
  Push-Location $AppDir
  & $exe @argList *>&1 | ForEach-Object { $line = $_.ToString(); Write-Host $line; Add-Content -Path $logFile -Value $line -Encoding UTF8 }
  $code = $LASTEXITCODE
  Pop-Location
  Add-Content -Path $logFile -Value "===== EXIT $code =====" -Encoding UTF8
  return $code
}

Set-Content -Path $SetupLog -Value "NearbyChat Flutter setup log $(Get-Date)"
Refresh-Path

# --- git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Log 'git not found, installing with winget...'
  winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements *>&1 | Out-String | Add-Content $SetupLog
  Refresh-Path
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $gitDefault = 'C:\Program Files\Git\cmd'
    if (Test-Path $gitDefault) { $env:Path += ";$gitDefault" }
  }
}
if (Get-Command git -ErrorAction SilentlyContinue) { Log ("git OK: " + (git --version)) } else { Log 'ERROR: git still missing' }

# --- flutter ---
if (-not (Test-Path (Join-Path $FlutterBin 'flutter.bat'))) {
  $existing = Get-Command flutter -ErrorAction SilentlyContinue
  if ($existing) {
    $FlutterBin = Split-Path -Parent $existing.Source
    Log "Using existing Flutter at $FlutterBin"
  } else {
    Log 'Downloading Flutter stable release index...'
    $base = 'https://storage.googleapis.com/flutter_infra_release/releases'
    $idx = Invoke-RestMethod "$base/releases_windows.json"
    $hash = $idx.current_release.stable
    $rel = $idx.releases | Where-Object { $_.hash -eq $hash -and $_.channel -eq 'stable' } | Select-Object -First 1
    Log "Latest stable: $($rel.version)"
    $zip = Join-Path $env:TEMP 'flutter_stable.zip'
    $ProgressPreference = 'SilentlyContinue'
    Log "Downloading $($rel.archive) (about 1 GB, takes a while)..."
    Invoke-WebRequest "$base/$($rel.archive)" -OutFile $zip
    Log "Extracting to $InstallDir ..."
    tar -xf $zip -C $InstallDir
    Remove-Item $zip -ErrorAction SilentlyContinue
  }
}
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -notlike "*$FlutterBin*") {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$FlutterBin", 'User')
  Log "Added $FlutterBin to user PATH"
}
$env:Path += ";$FlutterBin"
$flutter = Join-Path $FlutterBin 'flutter.bat'

$null = Run-Logged 'config'  $flutter @('config','--no-analytics') $SetupLog
$null = Run-Logged 'version' $flutter @('--version') $SetupLog
$null = Run-Logged 'doctor'  $flutter @('doctor','-v') $SetupLog
$null = Run-Logged 'pub get' $flutter @('pub','get') $SetupLog
$null = Run-Logged 'analyze' $flutter @('analyze') $SetupLog
$null = Run-Logged 'test'    $flutter @('test') $SetupLog
Set-Content -Path (Join-Path $LogDir 'setup.done') -Value (Get-Date)
Log 'Setup finished. Runner is now waiting for requests (close window to stop).'

# --- runner loop (fixed command list only) ---
$allowed = @{
  'pub-get'   = @('pub','get');
  'analyze'   = @('analyze');
  'test'      = @('test');
  'doctor'    = @('doctor','-v');
  'devices'   = @('devices');
  'build-apk' = @('build','apk','--debug');
}
Set-Content -Path (Join-Path $ToolsDir 'runner\alive.txt') -Value (Get-Date)
while ($true) {
  Set-Content -Path (Join-Path $ToolsDir 'runner\alive.txt') -Value (Get-Date)
  Get-ChildItem $Inbox -Filter *.txt -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
    $id  = $_.BaseName
    $cmd = (Get-Content $_.FullName -Raw).Trim()
    Remove-Item $_.FullName -Force
    $log = Join-Path $OutDir "$id.log"
    Set-Content -Path $log -Value "request $id : $cmd  ($(Get-Date))" -Encoding UTF8
    if ($allowed.ContainsKey($cmd)) {
      Write-Host "Running flutter $($allowed[$cmd] -join ' ')" -ForegroundColor Yellow
      $code = Run-Logged $cmd $flutter $allowed[$cmd] $log
    } else {
      Add-Content $log "Rejected: '$cmd' is not in the allowed list"
      $code = 99
    }
    Set-Content -Path (Join-Path $OutDir "$id.done") -Value $code
  }
  Start-Sleep -Seconds 2
}
