# Hermetic checks of the thin Windows bootstrap (scripts/install.ps1): it only
# resolves a release, downloads + SHA-256 verifies the bundle and runs
# `ham-bridge.exe setup --headless`. These cases use -Bundle/-ChecksumFile, so
# nothing is downloaded, and every case fails or stops before ham-bridge would run;
# the install itself is ham-bridge's (tested in the odin packages).
param([string]$Engine = 'powershell')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repo 'scripts\install.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-ps1-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failures = 0
function Get-BootstrapTemps { @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^heimdall-install-[0-9a-f]{32}$' } | ForEach-Object Name) }
$tempsBefore = Get-BootstrapTemps

function Invoke-Bootstrap([string[]]$ArgList) {
  $exe = if ($Engine -eq 'pwsh') { 'pwsh' } else { 'powershell.exe' }
  $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script @ArgList 2>&1 | Out-String
  return @{ Code = $LASTEXITCODE; Out = $out }
}
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name`n$Detail"; $script:failures++ }
}

try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $src = Join-Path $tmp 'src'
  New-Item -ItemType Directory -Path (Join-Path $src 'bin') | Out-Null
  Set-Content -Encoding ascii -Path (Join-Path $src 'bin\README.txt') -Value 'no ham-bridge.exe here'
  $zip = Join-Path $tmp 'heimdall-local-windows-amd64-v1.0.0.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
  $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
  $sums = Join-Path $tmp 'SHA256SUMS'
  Set-Content -Encoding ascii -Path $sums -Value "$hash  heimdall-local-windows-amd64-v1.0.0.zip"
  $bad = Join-Path $tmp 'BAD'
  Set-Content -Encoding ascii -Path $bad -Value ("0" * 64 + "  heimdall-local-windows-amd64-v1.0.0.zip")

  $r = Invoke-Bootstrap @('-Bundle', $zip, '-ChecksumFile', $bad, '-Hub', 'https://h.example')
  Check 'tampered bundle is refused' ($r.Code -ne 0 -and $r.Out -match 'SHA-256 verification failed') $r.Out

  $r = Invoke-Bootstrap @('-Bundle', $zip, '-ChecksumFile', $sums, '-Hub', 'https://h.example')
  Check 'verified bundle without ham-bridge.exe is refused' ($r.Code -ne 0 -and $r.Out -match 'SHA-256 verified' -and $r.Out -match 'no bin\\ham-bridge.exe') $r.Out

  $other = Join-Path $tmp 'heimdall-local-linux-amd64-v1.0.0.zip'
  Copy-Item $zip $other
  $r = Invoke-Bootstrap @('-Bundle', $other, '-ChecksumFile', $sums, '-Hub', 'https://h.example')
  Check 'bundle for another target is refused' ($r.Code -ne 0 -and $r.Out -match 'not a windows-amd64 bundle') $r.Out

  $r = Invoke-Bootstrap @('-Version', '..\x', '-Hub', 'https://h.example')
  Check 'invalid tag is refused' ($r.Code -ne 0 -and $r.Out -match 'Invalid release tag') $r.Out

  $r = Invoke-Bootstrap @('-Help')
  Check '-Help prints usage' ($r.Code -eq 0 -and $r.Out -match 'Usage: install.ps1') $r.Out

  $leaked = @(Get-BootstrapTemps | Where-Object { $tempsBefore -notcontains $_ })
  Check 'temporary directories are removed' ($leaked.Count -eq 0) ($leaked -join ', ')
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'install.ps1 bootstrap checks passed'
