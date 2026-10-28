# Packages the windows-amd64 release bundle: <OutDir>/heimdall-local-windows-amd64.zip
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/package-windows-bundle.ps1 `
#     -BinDir <dir with ham-bridge.exe ham-ctl.exe ham-pty-host.exe> -Version v0.4.9 -OutDir dist
#
# Zip root: bin/ham-bridge.exe, bin/ham-ctl.exe, bin/ham-pty-host.exe,
# [bin/heimdall.exe], [scripts/apply-bridge-update.ps1], README.md, LICENSE,
# METADATA.json, bin/extensions/ (including hidden marketplace/plugin manifests).
# Entry names always use forward slashes (Windows PowerShell 5.1's
# ZipFile.CreateFromDirectory can write backslashes), and only regular files are
# written, so scripts/install.ps1's exact-name lookup and the bridge's
# self-update (`tar -xzf`, Windows' bsdtar reads zip) both see the same layout.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BinDir,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Target = 'windows-amd64'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($Target -ne 'windows-amd64') { throw "unsupported Windows release target: $Target" }

$entries = [ordered]@{}
foreach ($exe in @('ham-bridge.exe', 'ham-ctl.exe', 'ham-pty-host.exe')) {
  $p = Join-Path $BinDir $exe
  if (-not (Test-Path -PathType Leaf $p)) { throw "missing required release input: $p" }
  $entries["bin/$exe"] = $p
}
$manager = Join-Path $BinDir 'heimdall.exe'
if (Test-Path -PathType Leaf $manager) { $entries['bin/heimdall.exe'] = $manager }
$supervisor = Join-Path (Join-Path $repo 'scripts') 'apply-bridge-update.ps1'
if (Test-Path -PathType Leaf $supervisor) { $entries['scripts/apply-bridge-update.ps1'] = $supervisor }
$entries['README.md'] = Join-Path $repo 'README.md'
$entries['LICENSE'] = Join-Path $repo 'LICENSE'

# Keep assets inside bin so the Windows updater swaps/rolls them back together
# with their matching binaries. Both bridge and ctl search <exe_dir>/extensions.
$extensionRoot = Join-Path $repo 'extensions'
foreach ($required in @(
  'antigravity/plugin.json', 'antigravity/hooks.json', 'antigravity/hooks/hooks.json',
  'claude-code/.claude-plugin/plugin.json', 'claude-code/hooks/hooks.json',
  'codex/.codex-plugin/plugin.json', 'codex/hooks/hooks.json',
  '.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $extensionRoot $required) -PathType Leaf)) {
    throw "missing required extension asset: $required"
  }
}
foreach ($asset in Get-ChildItem -LiteralPath $extensionRoot -Recurse -Force -File) {
  # This compatibility alias is a git symlink on Unix and a text placeholder
  # in Windows checkouts. Ship the real JSON rather than either representation.
  if ($asset.FullName -eq (Join-Path $extensionRoot 'antigravity\hooks.json')) { continue }
  if ($asset.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "extension asset is a link: $($asset.FullName)" }
  $relative = $asset.FullName.Substring($extensionRoot.Length + 1).Replace('\', '/')
  $entries["bin/extensions/$relative"] = $asset.FullName
}
$entries['bin/extensions/antigravity/hooks.json'] = Join-Path $extensionRoot 'antigravity/hooks/hooks.json'

# Every shipped .exe must be a PE image (MZ), never a script or a stub.
foreach ($k in @($entries.Keys)) {
  if ($k -like '*.exe') {
    $b = [IO.File]::ReadAllBytes($entries[$k])
    if ($b.Length -lt 2 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw "$k is not a PE executable" }
  }
}

$commit = $env:GITHUB_SHA
if (-not $commit) {
  try { $commit = (& git -C $repo rev-parse --short=12 HEAD | Select-Object -First 1) } catch { $commit = '' }
  if (-not $commit) { $commit = 'unknown' }
}
$binaries = @($entries.Keys | Where-Object { $_ -like 'bin/*' } | ForEach-Object { ($_ -replace '^bin/', '') -replace '\.exe$', '' })
$meta = [ordered]@{
  product        = 'heimdall-local'
  version        = $Version
  target         = $Target
  commit         = "$commit"
  built_at       = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  binaries       = $binaries
  tls_dependency = 'none: the Windows bridge uses the system TLS stack (SChannel); socat/openssl are not needed.'
}
$metaText = ($meta | ConvertTo-Json) + "`n"

New-Item -ItemType Directory -Force $OutDir | Out-Null
$zipPath = Join-Path (Resolve-Path $OutDir).Path "heimdall-local-$Target.zip"
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
  $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($k in $entries.Keys) {
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $entries[$k], $k, [IO.Compression.CompressionLevel]::Optimal)
    }
    $e = $zip.CreateEntry('METADATA.json')
    $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding($false)))
    try { $w.Write($metaText) } finally { $w.Dispose() }
  } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
Write-Host "packaged $zipPath"
