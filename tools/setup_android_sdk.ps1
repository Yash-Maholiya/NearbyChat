# One time Android toolchain setup for building the NearbyChat APK on Windows.
# Installs Microsoft OpenJDK 17 (winget) and the Android command line SDK into
# %LOCALAPPDATA%\Android\Sdk, accepts the SDK licenses, points Flutter at both,
# then runs one debug APK build. Log: tools\logs\android_setup.log

$ErrorActionPreference = 'Continue'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $ToolsDir
$AppDir   = Join-Path $Root 'nearby_chat'
$Log      = Join-Path $ToolsDir 'logs\android_setup.log'
$Sdk      = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$flutter  = Join-Path $env:USERPROFILE 'dev\flutter\bin\flutter.bat'
New-Item -ItemType Directory -Force -Path (Split-Path $Log), $Sdk | Out-Null
Set-Content -Path $Log -Value "Android setup log $(Get-Date)" -Encoding UTF8

function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l -ForegroundColor Cyan; Add-Content $Log $l -Encoding UTF8 }
function Run($exe, $argList, $stdin = $null) {
  Add-Content $Log "`n===== $exe $argList =====" -Encoding UTF8
  if ($stdin) { $out = $stdin | & $exe @argList *>&1 } else { $out = & $exe @argList *>&1 }
  $out | ForEach-Object { $s = $_.ToString(); Write-Host $s; Add-Content $Log $s -Encoding UTF8 }
  Add-Content $Log "===== EXIT $LASTEXITCODE =====" -Encoding UTF8
}

# --- JDK 17 ---
$jdk = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $jdk) {
  Log 'Installing Microsoft OpenJDK 17 with winget...'
  winget install --id Microsoft.OpenJDK.17 -e --silent --accept-package-agreements --accept-source-agreements *>&1 | Out-String | Add-Content $Log -Encoding UTF8
  $jdk = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $jdk) { Log 'ERROR: JDK 17 not found after install'; exit 1 }
$env:JAVA_HOME = $jdk.FullName
$env:Path = "$($jdk.FullName)\bin;$env:Path"
Log "JDK: $($jdk.FullName)"

# --- Android command line tools ---
$sdkmanager = Join-Path $Sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path $sdkmanager)) {
  Log 'Finding latest Android command line tools...'
  $repo = (Invoke-WebRequest 'https://dl.google.com/android/repository/repository2-3.xml' -UseBasicParsing).Content
  $m = [regex]::Match($repo, 'commandlinetools-win-\d+_latest\.zip')
  if (-not $m.Success) { Log 'ERROR: could not find cmdline tools in repository index'; exit 1 }
  $zip = Join-Path $env:TEMP $m.Value
  $ProgressPreference = 'SilentlyContinue'
  Log "Downloading $($m.Value)..."
  Invoke-WebRequest "https://dl.google.com/android/repository/$($m.Value)" -OutFile $zip
  $tmp = Join-Path $env:TEMP 'cmdline-tools-extract'
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  tar -xf $zip -C (New-Item -ItemType Directory -Force -Path $tmp).FullName
  New-Item -ItemType Directory -Force -Path (Join-Path $Sdk 'cmdline-tools') | Out-Null
  Move-Item (Join-Path $tmp 'cmdline-tools') (Join-Path $Sdk 'cmdline-tools\latest') -Force
  Remove-Item $zip -ErrorAction SilentlyContinue
}
$env:ANDROID_HOME = $Sdk
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $Sdk, 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'User')

$yes = (1..40 | ForEach-Object { 'y' }) -join "`n"
Log 'Installing platform-tools, Android 36 platform and build tools (a few hundred MB)...'
Run $sdkmanager @('--install', 'platform-tools', 'platforms;android-36', 'build-tools;36.0.0') $yes
Run $sdkmanager @('--licenses') $yes

Log 'Pointing Flutter at the SDK and JDK...'
Run $flutter @('config', '--android-sdk', $Sdk)
Run $flutter @('config', '--jdk-dir', $jdk.FullName)
Run $flutter @('doctor', '--android-licenses') $yes
Run $flutter @('doctor', '-v')

Log 'Building a debug APK (first build downloads Gradle, takes several minutes)...'
Push-Location $AppDir
Run $flutter @('build', 'apk', '--debug')
Pop-Location
Set-Content -Path (Join-Path $ToolsDir 'logs\android_setup.done') -Value (Get-Date) -Encoding UTF8
Log 'Done. You can close this window.'
