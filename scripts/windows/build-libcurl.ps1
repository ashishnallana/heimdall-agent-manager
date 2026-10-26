# Builds the pinned libcurl for the Windows binaries: a static libcurl.lib
# (Schannel TLS, the Windows certificate store) and the static zlib.lib it
# links, both /MT, from the source tarballs pinned in nix/libcurl-pin.json (the
# same pin the Linux and macOS builds read). Every tarball is SHA-256 verified.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-libcurl.ps1 -OutDir <dir>
#
# Output: <dir>/lib/libcurl.lib, <dir>/lib/zlib.lib, <dir>/include, and
# <dir>/libcurl-pin.json (a copy of the pin it was built from). Pass
# <dir>/lib to scripts/windows/build.ps1 -CurlLibDir.
#
# Needs a VS developer environment (cl.exe, lib.exe; ilammy/msvc-dev-cmd in CI)
# and CMake (on the GitHub windows-2022 image). The release workflow caches
# <dir> keyed on the pin and this script.
#
# Feature set, matching nix/libcurl.nix: HTTP/HTTPS and WebSockets only, zlib,
# threaded resolver, proxies compiled in (httpc disables them per request); no
# other protocol, no HTTP/2, no IDN/PSL/brotli/zstd/libssh2/GSS-API, no NTLM,
# no cookies/netrc/alt-svc/HSTS/MIME, no compiled-in CA bundle or path.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Pin = '',
  [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Pin) { $Pin = Join-Path $repo 'nix\libcurl-pin.json' }
$pinData = Get-Content -Raw $Pin | ConvertFrom-Json

function Invoke-Checked([string]$what, [scriptblock]$block) {
  & $block
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# Download the first URL that yields a tarball with the pinned SHA-256.
function Get-PinnedTarball($entry, [string]$dest) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  foreach ($url in $entry.urls) {
    try {
      Write-Host "downloading $url"
      (New-Object Net.WebClient).DownloadFile($url, $dest)
    } catch {
      Write-Host "  failed: $($_.Exception.Message)"
      continue
    }
    $got = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLowerInvariant()
    if ($got -eq $entry.sha256.ToLowerInvariant()) { return }
    Write-Host "  SHA-256 mismatch: $got"
  }
  throw "no URL produced $(Split-Path -Leaf $dest) with SHA-256 $($entry.sha256)"
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-libcurl-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$libDir = Join-Path $OutDir 'lib'
$incDir = Join-Path $OutDir 'include'
New-Item -ItemType Directory -Force $libDir, $incDir | Out-Null
try {
  # ---- zlib: compiled directly (its CMake names the static library per
  # version); /MT to match libcurl, sqlite3.lib and the Odin link.
  $zv = $pinData.zlib.version
  $zTar = Join-Path $WorkDir "zlib-$zv.tar.gz"
  Get-PinnedTarball $pinData.zlib $zTar
  Invoke-Checked 'tar zlib' { & tar -xzf $zTar -C $WorkDir }
  $zSrc = Join-Path $WorkDir "zlib-$zv"
  $zObj = Join-Path $WorkDir 'zlib-obj'
  New-Item -ItemType Directory -Force $zObj | Out-Null
  $zFiles = 'adler32', 'compress', 'crc32', 'deflate', 'gzclose', 'gzlib', 'gzread', 'gzwrite', 'infback', 'inffast', 'inflate', 'inftrees', 'trees', 'uncompr', 'zutil' |
    ForEach-Object { Join-Path $zSrc "$_.c" }
  Write-Host "compiling zlib $zv (/MT)"
  Push-Location $zObj # objects land in the current directory
  try {
    Invoke-Checked 'cl zlib' { & cl.exe /nologo /c /O2 /MT /DNDEBUG /D_CRT_SECURE_NO_DEPRECATE /D_CRT_NONSTDC_NO_DEPRECATE "/I$zSrc" @zFiles }
  } finally { Pop-Location }
  Invoke-Checked 'lib zlib' { & lib.exe /nologo "/OUT:$(Join-Path $libDir 'zlib.lib')" (Get-ChildItem $zObj -Filter *.obj | ForEach-Object FullName) }
  Copy-Item (Join-Path $zSrc 'zlib.h'), (Join-Path $zSrc 'zconf.h') $incDir

  # ---- libcurl, Schannel, static, /MT.
  $cv = $pinData.curl.version
  $cTar = Join-Path $WorkDir "curl-$cv.tar.gz"
  Get-PinnedTarball $pinData.curl $cTar
  Invoke-Checked 'tar curl' { & tar -xzf $cTar -C $WorkDir }
  $cSrc = Join-Path $WorkDir "curl-$cv"
  $cBuild = Join-Path $WorkDir 'curl-build'
  $cInst = Join-Path $WorkDir 'curl-install'
  $cmakeArgs = @(
    '-S', $cSrc, '-B', $cBuild, '-G', 'Visual Studio 17 2022', '-A', 'x64',
    "-DCMAKE_INSTALL_PREFIX=$cInst",
    '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW', '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DCURL_STATIC_CRT=ON',
    '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_STATIC_LIBS=ON', '-DBUILD_CURL_EXE=OFF', '-DBUILD_TESTING=OFF',
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_LIBCURL_DOCS=OFF', '-DBUILD_MISC_DOCS=OFF', '-DENABLE_CURL_MANUAL=OFF',
    '-DCURL_USE_PKGCONFIG=OFF',
    '-DCURL_ENABLE_SSL=ON', '-DCURL_USE_SCHANNEL=ON', '-DCURL_USE_OPENSSL=OFF',
    '-DCURL_ZLIB=ON', "-DZLIB_INCLUDE_DIR=$incDir", "-DZLIB_LIBRARY=$(Join-Path $libDir 'zlib.lib')",
    '-DUSE_NGHTTP2=OFF', '-DUSE_LIBIDN2=OFF', '-DUSE_WIN32_IDN=OFF', '-DCURL_USE_LIBPSL=OFF',
    '-DCURL_USE_LIBSSH2=OFF', '-DCURL_USE_GSSAPI=OFF', '-DCURL_BROTLI=OFF', '-DCURL_ZSTD=OFF',
    '-DENABLE_THREADED_RESOLVER=ON', '-DENABLE_UNIX_SOCKETS=OFF', '-DCURL_DISABLE_WEBSOCKETS=OFF',
    '-DCURL_DISABLE_DICT=ON', '-DCURL_DISABLE_FILE=ON', '-DCURL_DISABLE_FTP=ON', '-DCURL_DISABLE_GOPHER=ON',
    '-DCURL_DISABLE_IMAP=ON', '-DCURL_DISABLE_LDAP=ON', '-DCURL_DISABLE_LDAPS=ON', '-DCURL_DISABLE_MQTT=ON',
    '-DCURL_DISABLE_POP3=ON', '-DCURL_DISABLE_RTSP=ON', '-DCURL_DISABLE_SMTP=ON',
    '-DCURL_DISABLE_TELNET=ON', '-DCURL_DISABLE_TFTP=ON', '-DCURL_DISABLE_IPFS=ON',
    # SMB needs NTLM, which stays off.
    '-DCURL_ENABLE_NTLM=OFF', '-DCURL_DISABLE_KERBEROS_AUTH=ON', '-DCURL_DISABLE_NEGOTIATE_AUTH=ON',
    '-DCURL_DISABLE_AWS=ON', '-DCURL_DISABLE_COOKIES=ON', '-DCURL_DISABLE_NETRC=ON', '-DCURL_DISABLE_ALTSVC=ON',
    '-DCURL_DISABLE_HSTS=ON', '-DCURL_DISABLE_MIME=ON', '-DCURL_DISABLE_FORM_API=ON',
    '-DCURL_DISABLE_LIBCURL_OPTION=ON',
    '-DCURL_CA_BUNDLE=none', '-DCURL_CA_PATH=none'
  )
  Write-Host "configuring curl $cv (Schannel, static, /MT)"
  Invoke-Checked 'cmake configure curl' { & cmake @cmakeArgs }
  Invoke-Checked 'cmake build curl' { & cmake --build $cBuild --config Release --parallel }
  Invoke-Checked 'cmake install curl' { & cmake --install $cBuild --config Release }
  $built = Join-Path $cInst 'lib\libcurl.lib'
  if (-not (Test-Path $built)) {
    $found = Get-ChildItem (Join-Path $cInst 'lib') -Filter *.lib | ForEach-Object Name
    throw "libcurl.lib not produced by the curl build (lib/ has: $($found -join ', '))"
  }
  Copy-Item $built $libDir
  Copy-Item -Recurse -Force (Join-Path $cInst 'include\curl') $incDir

  # The archive must carry exactly the pinned version string, and Schannel.
  $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $libDir 'libcurl.lib')))
  if (-not $text.Contains($cv)) { throw "libcurl.lib does not contain version string $cv" }
  if (-not $text.Contains('Schannel')) { throw 'libcurl.lib was not built with Schannel' }
  Copy-Item $Pin (Join-Path $OutDir 'libcurl-pin.json')
  Get-ChildItem $libDir | ForEach-Object { Write-Host ("built {0} ({1:N0} bytes)" -f $_.FullName, $_.Length) }
} finally {
  Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
