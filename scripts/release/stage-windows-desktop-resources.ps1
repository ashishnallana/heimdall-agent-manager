# REQ-WIN-DESKTOP-1: stage the verified Windows Bridge archive beside the
# Electron app. electron-builder copies this directory into resources\bridge;
# the desktop main process invokes install.ps1 with -Bundle/-ChecksumFile.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Bundle,
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$OutDir = 'release-assets\bridge'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$target = 'windows-amd64'
$archive = "heimdall-local-$target.zip"

if (-not (Test-Path -LiteralPath $Bundle -PathType Leaf)) { throw "missing Bridge bundle: $Bundle" }
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force $OutDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'scripts\install.ps1') -Destination (Join-Path $OutDir 'install.ps1')
Copy-Item -LiteralPath $Bundle -Destination (Join-Path $OutDir $archive)

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Bundle).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), "$hash  $archive`n", (New-Object Text.UTF8Encoding($false)))

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Bundle).Path)
try {
  $entry = @($zip.Entries | Where-Object { $_.FullName -ceq 'METADATA.json' })
  if ($entry.Count -ne 1) { throw 'Bridge bundle must contain exactly one root METADATA.json' }
  $reader = New-Object IO.StreamReader($entry[0].Open(), [Text.Encoding]::UTF8, $true)
  try { $metadataText = $reader.ReadToEnd() } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
$metadata = $metadataText | ConvertFrom-Json
if (("$($metadata.version)").TrimStart('v') -ne $Version.TrimStart('v')) {
  throw "bundle metadata version $($metadata.version) does not match requested $Version"
}
if ("$($metadata.target)" -ne $target) { throw "bundle metadata target $($metadata.target) is not $target" }
[IO.File]::WriteAllText((Join-Path $OutDir 'METADATA.json'), $metadataText.TrimEnd() + "`n", (New-Object Text.UTF8Encoding($false)))

Write-Host (Resolve-Path -LiteralPath $OutDir).Path
