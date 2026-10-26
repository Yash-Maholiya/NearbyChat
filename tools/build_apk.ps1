# Builds the NearbyChat Android APK and installs it on a phone connected by USB.
#  1. Installs the Android NDK the Flutter Gradle plugin asks for (the last build failed on this)
#  2. flutter test (includes the Python interop test)
#  3. flutter build apk --debug, copies it to FOR_ANDROID\NearbyChat.apk
#  4. If a phone with USB debugging is connected, installs the APK on it
# Log: tools\logs\apk_build.log

$ErrorActionPreference = 'Continue'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $ToolsDir
$AppDir   = Join-Path $Root 'nearby_chat'
$Log      = Join-Path $ToolsDir 'logs\apk_build.log'
$Sdk      = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$flutter  = Join-Path $env:USERPROFILE 'dev\flutter\bin\flutter.bat'
$NdkVer   = '28.2.13676358'
$jdk      = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1
New-Item -ItemType Directory -Force -Path (Join-Path $ToolsDir 'logs') | Out-Null
Set-Content -Path $Log -Value "APK build log $(Get-Date)" -Encoding UTF8
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l -ForegroundColor Cyan; Add-Content $Log $l -Encoding UTF8 }
function Out($lines) { $lines | ForEach-Object { $s = $_.ToString(); Write-Host $s; Add-Content $Log $s -Encoding UTF8 } }

if (-not (Test-Path $flutter)) { $f = Get-Command flutter.bat -ErrorAction SilentlyContinue; if ($f) { $flutter = $f.Source } }
if ($jdk) { $env:JAVA_HOME = $jdk.FullName; $env:Path = "$($jdk.FullName)\bin;$env:Path" }
$env:ANDROID_HOME = $Sdk
$env:GRADLE_OPTS = '-Djava.net.preferIPv4Stack=true'
Log "flutter: $flutter"
Log "JDK: $($env:JAVA_HOME)"

# ---------------- 1. NDK ----------------
$ndkDir = Join-Path $Sdk "ndk\$NdkVer"
if (Test-Path (Join-Path $ndkDir 'source.properties')) {
  Log "NDK $NdkVer already installed"
} else {
  Log "Installing NDK $NdkVer (about 700 MB, takes a few minutes)"
  $yes = (1..40 | ForEach-Object { 'y' }) -join "`r`n"
  $yesFile = Join-Path $env:TEMP 'yes.txt'
  $yes | Set-Content $yesFile -Encoding ASCII
  $sdkm = Join-Path $Sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
  # cmd /c with explicit quotes so the semicolon survives batch argument parsing
  Out (cmd /c "`"$sdkm`" --install `"ndk;$NdkVer`" < `"$yesFile`"" 2>&1 | Where-Object { $_ -notmatch 'ETA' -and $_ -notmatch '^\s*\[=*' })
  if (-not (Test-Path (Join-Path $ndkDir 'source.properties'))) {
    $cli = Get-ChildItem (Join-Path $Sdk 'cmdline-tools\latest\bin') -Filter 'android*.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cli) { $cli = Get-ChildItem (Join-Path $Sdk 'cmdline-tools\latest\bin') -Filter 'android*' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($cli) {
      Log "sdkmanager did not install it, trying $($cli.Name) sdk install"
      Out (cmd /c "`"$($cli.FullName)`" sdk install `"ndk;$NdkVer`" < `"$yesFile`"" 2>&1 | Where-Object { $_ -notmatch 'ETA' })
    }
  }
  if (-not (Test-Path (Join-Path $ndkDir 'source.properties'))) {
    Log 'Still no NDK, downloading the zip directly from dl.google.com'
    $zip = Join-Path $env:TEMP "android-ndk-r28c-windows.zip"
    $ProgressPreference = 'SilentlyContinue'
    try {
      Invoke-WebRequest 'https://dl.google.com/android/repository/android-ndk-r28c-windows.zip' -OutFile $zip -UseBasicParsing
      $tmp = Join-Path $env:TEMP 'ndk_unzip'
      Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
      Expand-Archive $zip -DestinationPath $tmp -Force
      $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
      New-Item -ItemType Directory -Force -Path (Join-Path $Sdk 'ndk') | Out-Null
      Move-Item $inner.FullName $ndkDir -Force
      $rev = (Select-String -Path (Join-Path $ndkDir 'source.properties') -Pattern 'Pkg.Revision').Line
      Log "Unpacked NDK: $rev"
    } catch { Log "Direct NDK download failed: $_" }
  }
  Log ("NDK folders now: " + ((Get-ChildItem (Join-Path $Sdk 'ndk') -ErrorAction SilentlyContinue).Name -join ', '))
}

# ---------------- 2. tests ----------------
Push-Location $AppDir
Log 'flutter pub get'
Out (& $flutter pub get *>&1)
Log 'flutter analyze'
Out (& $flutter analyze *>&1 | Select-Object -Last 30)
Log "ANALYZE EXIT $LASTEXITCODE"
Log 'flutter test'
Out (& $flutter test *>&1 | Select-Object -Last 25)
Log "TEST EXIT $LASTEXITCODE"

# ---------------- 3. build ----------------
# Release build for 64 bit ARM phones (almost every phone since 2017): about 20 MB instead of
# 150 MB for a debug build. Signed with the debug key (see android/app/build.gradle.kts).
Log 'flutter build apk --release --target-platform android-arm64 (first build takes several minutes)'
Out (& $flutter build apk --release --target-platform android-arm64 *>&1)
$code = $LASTEXITCODE
$apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) {
  Log 'Release build failed, falling back to a debug build'
  Out (& $flutter build apk --debug *>&1)
  $code = $LASTEXITCODE
  $apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-debug.apk'
}
Pop-Location
Log "BUILD EXIT $code"
if (Test-Path $apk) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Root 'FOR_ANDROID') | Out-Null
  Copy-Item $apk (Join-Path $Root 'FOR_ANDROID\NearbyChat.apk') -Force
  Log ("APK ready: $Root\FOR_ANDROID\NearbyChat.apk ({0:N1} MB)" -f ((Get-Item $apk).Length / 1MB))

  # ---------------- 4. install ----------------
  $adb = Join-Path $Sdk 'platform-tools\adb.exe'
  if (Test-Path $adb) {
    $devs = (& $adb devices) | Select-String "`tdevice$"
    if ($devs) {
      Log "Installing on connected phone: $($devs[0].Line)"
      Out (& $adb install -r $apk *>&1)
      Out (& $adb shell monkey -p com.nearbychat.nearby_chat -c android.intent.category.LAUNCHER 1 *>&1)
      Log 'Installed and started on the phone'
    } else {
      Log 'No phone with USB debugging found. Copy FOR_ANDROID\NearbyChat.apk to the phone (USB, Drive, WhatsApp) and open it to install.'
    }
  }
} else {
  Log 'No APK produced, see the errors above.'
}
Set-Content -Path (Join-Path $ToolsDir 'logs\apk_build.done') -Value "$code $(Get-Date)" -Encoding UTF8
Log 'Done. You can close this window.'
