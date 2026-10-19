# P2.5 passwordless-vault API end-to-end test (docs/plans/passwordless-vault.md §2).
# Builds ham-hub from this tree into %USERPROFILE%\.cache\heimdall-e2e, then runs
# tests/e2e/vault_devices_api_e2e.mjs, which starts a THROWAWAY hub (ephemeral port,
# temp DB and dirs) and never touches a running dev hub/bridge or the OS keystore.
#
#   powershell -File scripts/e2e-vault-devices.ps1 [-SkipBuild]
# Env: ODIN (odin.exe), HEIMDALL_SQLITE_LIBPATH (dir holding sqlite3.lib).
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$odin = if ($env:ODIN) { $env:ODIN } else { Join-Path $env:LOCALAPPDATA 'Programs\Odin\dist\odin.exe' }
$libpath = if ($env:HEIMDALL_SQLITE_LIBPATH) { $env:HEIMDALL_SQLITE_LIBPATH } else { Join-Path $env:USERPROFILE 'heimdall-win-build\deps\lib' }
$outDir = Join-Path $env:USERPROFILE '.cache\heimdall-e2e'
$hub = Join-Path $outDir 'ham-hub-e2e.exe'
New-Item -ItemType Directory -Force $outDir | Out-Null

if (-not $SkipBuild) {
  Write-Host "building hub -> $hub"
  & $odin build (Join-Path $repo 'src/hub') "-collection:odin_test=$(Join-Path $repo 'src')" "-extra-linker-flags:/LIBPATH:$($libpath -replace '\\','/')" "-out:$hub"
  if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL hub build'; exit 1 }
}

$env:HEIMDALL_E2E_HUB_BIN = $hub
$env:HEIMDALL_E2E_MIGRATIONS_DIR = Join-Path $repo 'src/hub/repository/sqlite/migrations'
Push-Location $repo
try {
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/vault_devices_api_e2e.mjs
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}
exit $code
