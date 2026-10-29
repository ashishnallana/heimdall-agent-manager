# Real `ham-bridge enroll` against throwaway hubs (tests/e2e/bridge_real_enroll_e2e.mjs):
# one-code pairing, first unseal with pair_mac, hub binding, instance lock and two
# bridges for two hubs on one machine. Builds ham-hub and ham-bridge from this tree
# into %USERPROFILE%\.cache\heimdall-e2e. Temp HOME/config/token dirs, ephemeral
# ports; every Credential Manager item it writes is scoped to a random-port
# 127.0.0.1 hub and is deleted at the end.
#
# -Lifecycle also runs tests/e2e/bridge_lifecycle_e2e.mjs (enroll -> re-enroll ->
# replace account -> setup/update when HEIMDALL_E2E_SERVICE=1 -> uninstall --purge,
# asserting no files, Credential Manager items, scheduled task or hub rows remain).
# -SkipBuild keeps HEIMDALL_E2E_HUB_BIN / HEIMDALL_E2E_BRIDGE_BIN when they are set (CI).
#
#   powershell -File scripts/e2e-bridge-enroll.ps1 [-SkipBuild] [-Lifecycle]
param([switch]$SkipBuild, [switch]$Lifecycle)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$odin = if ($env:ODIN) { $env:ODIN } else { Join-Path $env:LOCALAPPDATA 'Programs\Odin\dist\odin.exe' }
$libpath = if ($env:HEIMDALL_SQLITE_LIBPATH) { $env:HEIMDALL_SQLITE_LIBPATH } else { Join-Path $env:USERPROFILE 'heimdall-win-build\deps\lib' }
$outDir = Join-Path $env:USERPROFILE '.cache\heimdall-e2e'
$hub = Join-Path $outDir 'ham-hub-e2e.exe'
$bridge = Join-Path $outDir 'ham-bridge-e2e.exe'
New-Item -ItemType Directory -Force $outDir | Out-Null
if (-not $SkipBuild) {
  foreach ($pair in @(@('src/hub', $hub), @('src/bridge', $bridge))) {
    Write-Host "building $($pair[0]) -> $($pair[1])"
    & $odin build (Join-Path $repo $pair[0]) "-collection:odin_test=$(Join-Path $repo 'src')" "-extra-linker-flags:/LIBPATH:$($libpath -replace '\\','/')" "-out:$($pair[1])"
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL build $($pair[0])"; exit 1 }
  }
}
if (-not ($SkipBuild -and $env:HEIMDALL_E2E_HUB_BIN)) { $env:HEIMDALL_E2E_HUB_BIN = $hub }
if (-not ($SkipBuild -and $env:HEIMDALL_E2E_BRIDGE_BIN)) { $env:HEIMDALL_E2E_BRIDGE_BIN = $bridge }
Push-Location $repo
try {
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
  $code = $LASTEXITCODE
  if ($Lifecycle) {
    node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_lifecycle_e2e.mjs
    if ($LASTEXITCODE -ne 0) { $code = $LASTEXITCODE }
  }
} finally {
  Pop-Location
}
exit $code
