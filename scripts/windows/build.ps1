# Builds the Windows bridge binaries (the windows-amd64 release bundle's bin/):
# ham-bridge.exe and ham-ctl.exe (Odin, hub-less) and ham-pty-host.exe (Rust).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build.ps1 -OutDir <dir>
#
# ham-bridge links a static sqlite3.lib (task-chain search, FTS5). Pass
# -SqliteLibDir to reuse one, else it is compiled here from the official
# amalgamation (downloaded and SHA-256 verified unless -SqliteAmalgamationDir):
# /MT, SQLITE_ENABLE_FTS5, SQLITE_OMIT_LOAD_EXTENSION, SQLITE_THREADSAFE=1.
# Compiling SQLite needs cl.exe and lib.exe on PATH (a VS developer shell, or
# ilammy/msvc-dev-cmd in CI); Odin needs the MSVC linker either way.
#
# ham-bridge and ham-ctl link libcurl through src/lib/httpc: the static
# libcurl.lib (Schannel TLS, Windows certificate store) and zlib.lib built by
# scripts/windows/build-libcurl.ps1 from the version pinned in
# nix/libcurl-pin.json, so no curl DLL is needed at runtime. Pass their
# directory as -CurlLibDir, or omit it to build them here first. The pinned
# version is compiled in (-define:HAM_CURL_VERSION) and httpc.init() refuses
# any other libcurl. The Odin toolchain's own vendor/curl/lib/libcurl.lib is
# NOT used: it is an unpinned 8.17.0-DEV snapshot without zlib.
#
# ham-pty-host is built with a static CRT (+crt-static) so the bundle runs on a
# stock Windows without the VC++ redistributable (no VCRUNTIME140.dll).
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Odin = '',
  [string]$SqliteLibDir = '',
  [string]$SqliteAmalgamationDir = '',
  [string]$PtyHost = '',
  [string]$CurlLibDir = '',
  [string]$Version = '',
  [string[]]$Components = @('ham-bridge', 'ham-ctl', 'ham-pty-host')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Pinned SQLite amalgamation (3.54.1); bump both together.
$SqliteZipUrl = 'https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip'
$SqliteZipSha256 = '0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9'

function Invoke-Checked([string]$what, [scriptblock]$block) {
  & $block
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

if (-not $Odin) {
  $cmd = Get-Command odin -ErrorAction SilentlyContinue
  if ($cmd) { $Odin = $cmd.Source } else { $Odin = Join-Path $env:LOCALAPPDATA 'Programs\Odin\dist\odin.exe' }
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-winbuild-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
  $needOdin = ($Components -contains 'ham-bridge') -or ($Components -contains 'ham-ctl')
  if (($Components -contains 'ham-bridge') -and -not $SqliteLibDir) {
    if (-not $SqliteAmalgamationDir) {
      $zip = Join-Path $work 'sqlite.zip'
      Write-Host "downloading $SqliteZipUrl"
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      (New-Object Net.WebClient).DownloadFile($SqliteZipUrl, $zip)
      $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
      if ($got -ne $SqliteZipSha256) { throw "SQLite amalgamation SHA-256 mismatch: $got" }
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $work 'sqlite'))
      $SqliteAmalgamationDir = (Get-ChildItem (Join-Path $work 'sqlite') -Directory | Select-Object -First 1).FullName
    }
    $src = Join-Path $SqliteAmalgamationDir 'sqlite3.c'
    if (-not (Test-Path $src)) { throw "sqlite3.c not found in $SqliteAmalgamationDir" }
    $SqliteLibDir = Join-Path $work 'sqlite-lib'
    New-Item -ItemType Directory $SqliteLibDir | Out-Null
    $obj = Join-Path $SqliteLibDir 'sqlite3.obj'
    Write-Host 'compiling sqlite3.lib (FTS5, /MT)'
    Invoke-Checked 'cl sqlite3.c' { & cl.exe /nologo /c /O2 /MT /DSQLITE_ENABLE_FTS5 /DSQLITE_OMIT_LOAD_EXTENSION /DSQLITE_THREADSAFE=1 $src "/Fo$obj" }
    Invoke-Checked 'lib sqlite3.obj' { & lib.exe /nologo "/OUT:$(Join-Path $SqliteLibDir 'sqlite3.lib')" $obj }
  }
  if ($needOdin) {
    $defines = @()
    if ($Version) { $defines += "-define:HAM_APP_VERSION=$($Version.TrimStart('v'))" }
    $srcRoot = (Join-Path $repo 'src') -replace '\\', '/'
    $pin = Get-Content -Raw (Join-Path $repo 'nix\libcurl-pin.json') | ConvertFrom-Json
    $defines += "-define:HAM_CURL_VERSION=$($pin.curl.version)"
    if (-not $CurlLibDir) {
      $curlOut = Join-Path $work 'libcurl'
      & (Join-Path $PSScriptRoot 'build-libcurl.ps1') -OutDir $curlOut # throws on failure
      $CurlLibDir = Join-Path $curlOut 'lib'
    }
    foreach ($lib in 'libcurl.lib', 'zlib.lib') {
      if (-not (Test-Path (Join-Path $CurlLibDir $lib))) { throw "$lib not found in $CurlLibDir (build it with scripts/windows/build-libcurl.ps1)" }
    }
    $curlLibDir = (Resolve-Path $CurlLibDir).Path
    foreach ($pair in @(@('ham-bridge', 'src/bridge'), @('ham-ctl', 'src/ctl'))) {
      if ($Components -notcontains $pair[0]) { continue }
      $out = Join-Path $OutDir ($pair[0] + '.exe')
      $odinArgs = @('build', (Join-Path $repo $pair[1]), "-collection:odin_test=$srcRoot", "-out:$out") + $defines
      $libPaths = "/LIBPATH:$($curlLibDir -replace '\\', '/')"
      if ($pair[0] -eq 'ham-bridge') { $libPaths += " /LIBPATH:$($SqliteLibDir -replace '\\', '/')" }
      $odinArgs += "-extra-linker-flags:$libPaths"
      Write-Host "odin build $($pair[1]) -> $out"
      Invoke-Checked "odin build $($pair[1])" { & $Odin @odinArgs }
    }
  }
  if ($Components -contains 'ham-pty-host') {
    $dest = Join-Path $OutDir 'ham-pty-host.exe'
    if ($PtyHost) {
      Copy-Item -Force $PtyHost $dest
    } else {
      $manifest = Join-Path $repo 'tools\pty_host\Cargo.toml'
      $oldFlags = $env:RUSTFLAGS
      $env:RUSTFLAGS = (($oldFlags, '-C target-feature=+crt-static') | Where-Object { $_ }) -join ' '
      try {
        Write-Host 'cargo build ham-pty-host (static CRT)'
        Invoke-Checked 'cargo build ham-pty-host' { & cargo build --release --locked --manifest-path $manifest }
      } finally { $env:RUSTFLAGS = $oldFlags }
      Copy-Item -Force (Join-Path $repo 'tools\pty_host\target\release\ham-pty-host.exe') $dest
    }
  }
  Get-ChildItem $OutDir -Filter *.exe | ForEach-Object { Write-Host ("built {0} ({1:N0} bytes)" -f $_.FullName, $_.Length) }
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
