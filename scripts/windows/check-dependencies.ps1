# Packaging gate for the Windows bundle: every .exe in -BinDir may import only
# DLLs that ship with Windows. Rejected outright, even when a copy happens to
# sit in System32 on the build machine: libcurl, OpenSSL (libssl/libcrypto),
# zlib and sqlite DLLs (all linked statically) and the Visual C++ runtime
# (vcruntime*/msvcp*: the binaries use the static CRT, /MT and +crt-static).
# Everything else must exist in %SystemRoot%\System32 or be an API set
# (api-ms-win-* / ext-ms-win-*), which Windows resolves itself.
#
#   powershell -NoProfile -File scripts/windows/check-dependencies.ps1 -BinDir <dir>
#
# Needs dumpbin (a VS developer environment) or llvm-readobj on PATH.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$BinDir)
$ErrorActionPreference = 'Stop'

function Get-Dependents([string]$exe) {
  if (Get-Command dumpbin -ErrorAction SilentlyContinue) {
    $out = & dumpbin /nologo /dependents $exe
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $exe" }
    return $out | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '(?i)^[^\s\\/:]+\.dll$' }
  }
  if (Get-Command llvm-readobj -ErrorAction SilentlyContinue) {
    $out = & llvm-readobj --coff-imports $exe
    if ($LASTEXITCODE -ne 0) { throw "llvm-readobj failed on $exe" }
    return $out | Select-String -Pattern '^\s*Name:\s*(\S+\.dll)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
  }
  throw 'need dumpbin or llvm-readobj on PATH'
}

$denied = '(?i)^(libcurl.*|curl.*|libssl.*|libcrypto.*|ssleay.*|libeay.*|zlib.*|libz.*|sqlite3.*|vcruntime.*|msvcp.*)\.dll$'
$system32 = Join-Path $env:SystemRoot 'System32'
$failures = @()
$exes = Get-ChildItem $BinDir -Filter *.exe
if (-not $exes) { throw "no .exe in $BinDir" }
foreach ($exe in $exes) {
  $deps = @(Get-Dependents $exe.FullName | Sort-Object -Unique)
  Write-Host "$($exe.Name): $($deps -join ', ')"
  foreach ($dll in $deps) {
    if ($dll -match $denied) {
      $failures += "$($exe.Name) imports $dll; libcurl, OpenSSL, zlib, sqlite and the VC++ runtime must be linked statically"
    } elseif ($dll -match '(?i)^(api|ext)-ms-win-') {
      continue
    } elseif (-not (Test-Path (Join-Path $system32 $dll))) {
      $failures += "$($exe.Name) imports $dll, which is not a Windows system DLL"
    }
  }
}
if ($failures) { throw ("Windows dependency gate failed:`n" + ($failures -join "`n")) }
Write-Host 'Windows dependency gate: OK (system DLLs only)'
