# Fixes the Android build setup and retries the APK build.
#  1. Network check: PowerShell and Java (default and IPv4 only) against the hosts the build needs
#  2. Installs Android platform 36, build tools and platform tools (quoted correctly this time)
#  3. Pre-downloads Gradle 9.1.0 with PowerShell into the folder the Gradle wrapper looks in
#  4. Runs flutter build apk --debug
# Log: tools\logs\android_fix.log

$ErrorActionPreference = 'Continue'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $ToolsDir
$AppDir   = Join-Path $Root 'nearby_chat'
$Log      = Join-Path $ToolsDir 'logs\android_fix.log'
$Sdk      = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$flutter  = Join-Path $env:USERPROFILE 'dev\flutter\bin\flutter.bat'
$jdk      = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1
Set-Content -Path $Log -Value "Android fix log $(Get-Date)" -Encoding UTF8
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l -ForegroundColor Cyan; Add-Content $Log $l -Encoding UTF8 }
function Out($lines) { $lines | ForEach-Object { $s = $_.ToString(); Write-Host $s; Add-Content $Log $s -Encoding UTF8 } }

$env:JAVA_HOME = $jdk.FullName
$env:ANDROID_HOME = $Sdk
$env:Path = "$($jdk.FullName)\bin;$env:Path"
Log "JDK $($jdk.FullName)"

# ---------------- 1. network check ----------------
Log 'NETWORK CHECK'
$hosts = @('services.gradle.org','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com',
           'dl.google.com','maven.google.com','repo.maven.apache.org','plugins.gradle.org')
foreach ($h in $hosts) {
  $v4 = (Resolve-DnsName $h -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
  $v6 = (Resolve-DnsName $h -Type AAAA -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
  $tcp = Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue
  Log ("{0,-40} tcp443={1} ipv4={2} ipv6={3} via={4}" -f $h, $tcp.TcpTestSucceeded, $v4, $v6, $tcp.RemoteAddress)
}
$proxy = netsh winhttp show proxy | Out-String
Log ("WinHTTP proxy: " + ($proxy -replace '\s+', ' '))
Log ("User proxy enabled: " + (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyEnable)

$java = @'
import java.net.*;
public class NetCheck {
  public static void main(String[] a) throws Exception {
    String[] urls = {
      "https://services.gradle.org/distributions/gradle-9.1.0-all.zip.sha256",
      "https://services.gradle.org/distributions/gradle-9.1.0-all.zip",
      "https://dl.google.com/dl/android/maven2/master-index.xml",
      "https://repo.maven.apache.org/maven2/",
      "https://plugins.gradle.org/m2/"
    };
    for (String u : urls) {
      long t = System.currentTimeMillis();
      try {
        HttpURLConnection c = (HttpURLConnection) new URL(u).openConnection();
        c.setConnectTimeout(15000); c.setReadTimeout(15000); c.setRequestMethod("HEAD");
        c.setInstanceFollowRedirects(true);
        int code = c.getResponseCode();
        System.out.println("JAVA OK   " + code + " " + (System.currentTimeMillis() - t) + "ms " + u + " -> " + c.getURL().getHost());
      } catch (Exception e) {
        System.out.println("JAVA FAIL " + (System.currentTimeMillis() - t) + "ms " + u + " : " + e);
      }
    }
  }
}
'@
$jf = Join-Path $env:TEMP 'NetCheck.java'
Set-Content -Path $jf -Value $java -Encoding ASCII
Log 'Java, default settings:'
Out (& java $jf *>&1)
Log 'Java, -Djava.net.preferIPv4Stack=true:'
Out (& java '-Djava.net.preferIPv4Stack=true' $jf *>&1)

# ---------------- 2. SDK packages ----------------
Log 'SDK PACKAGES'
$sdkm = Join-Path $Sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
$yes = (1..40 | ForEach-Object { 'y' }) -join "`r`n"
$yes | Set-Content (Join-Path $env:TEMP 'yes.txt') -Encoding ASCII
# cmd /c with explicit quotes so the semicolons survive batch argument parsing
$cmdline = "`"$sdkm`" --install `"platform-tools`" `"platforms;android-36`" `"build-tools;36.0.0`" < `"$env:TEMP\yes.txt`""
Out (cmd /c $cmdline 2>&1 | Where-Object { $_ -notmatch '^\s*\[=*' -and $_ -notmatch 'ETA' })
Log ("platforms now: " + ((Get-ChildItem (Join-Path $Sdk 'platforms') -ErrorAction SilentlyContinue).Name -join ', '))
Log ("build-tools now: " + ((Get-ChildItem (Join-Path $Sdk 'build-tools') -ErrorAction SilentlyContinue).Name -join ', '))
Log ("licenses dir: " + ((Get-ChildItem (Join-Path $Sdk 'licenses') -ErrorAction SilentlyContinue).Name -join ', '))
if (-not (Get-ChildItem (Join-Path $Sdk 'platforms') -ErrorAction SilentlyContinue)) {
  $cli = Get-ChildItem (Join-Path $Sdk 'cmdline-tools\latest\bin') -Filter 'android*' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cli) {
    Log "sdkmanager did not install the platform, trying $($cli.Name) sdk install"
    Out (cmd /c "`"$($cli.FullName)`" sdk install `"platforms;android-36`" `"build-tools;36.0.0`" < `"$env:TEMP\yes.txt`"" 2>&1 |
         Where-Object { $_ -notmatch 'ETA' })
    Log ("platforms now: " + ((Get-ChildItem (Join-Path $Sdk 'platforms') -ErrorAction SilentlyContinue).Name -join ', '))
  }
}

# ---------------- 3. Gradle distribution ----------------
Log 'GRADLE'
$distDir = Join-Path $env:USERPROFILE '.gradle\wrapper\dists\gradle-9.1.0-all\7wzd0jkjit61aq2p43wpjgij9'
$zip = Join-Path $distDir 'gradle-9.1.0-all.zip'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if (-not (Test-Path (Join-Path $distDir 'gradle-9.1.0\bin\gradle.bat'))) {
  Remove-Item "$zip.part", "$zip.lck" -ErrorAction SilentlyContinue
  if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 100MB) {
    Log 'Downloading gradle-9.1.0-all.zip with PowerShell (about 220 MB)...'
    $ProgressPreference = 'SilentlyContinue'
    try {
      Invoke-WebRequest 'https://services.gradle.org/distributions/gradle-9.1.0-all.zip' -OutFile $zip -UseBasicParsing
      Log ("Downloaded {0:N0} MB" -f ((Get-Item $zip).Length / 1MB))
    } catch { Log "PowerShell download failed too: $_" }
  }
} else { Log 'Gradle 9.1.0 already unpacked' }

# Java networking for the rest of the build (plugins and libraries from Maven)
$env:GRADLE_OPTS = '-Djava.net.preferIPv4Stack=true'
$gp = Join-Path $env:USERPROFILE '.gradle\gradle.properties'
if (-not (Test-Path $gp) -or -not (Select-String -Path $gp -Pattern 'preferIPv4Stack' -Quiet)) {
  Add-Content $gp "`nsystemProp.java.net.preferIPv4Stack=true" -Encoding ASCII
  Log "Added preferIPv4Stack to $gp"
}

# ---------------- 4. build ----------------
Log 'FLUTTER DOCTOR (Android)'
Out ((& $flutter doctor -v *>&1) | Select-String -Pattern 'Android|SDK|Java|platform|X ' -SimpleMatch:$false)
Log 'BUILD APK (first build downloads Android Gradle plugin and libraries, several minutes)'
Push-Location $AppDir
Out (& $flutter build apk --debug *>&1)
$code = $LASTEXITCODE
Pop-Location
Log "BUILD EXIT $code"
$apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-debug.apk'
if (Test-Path $apk) { Log ("APK: $apk ({0:N1} MB)" -f ((Get-Item $apk).Length / 1MB)) }
Set-Content -Path (Join-Path $ToolsDir 'logs\android_fix.done') -Value "$code $(Get-Date)" -Encoding UTF8
Log 'Done. You can close this window.'
