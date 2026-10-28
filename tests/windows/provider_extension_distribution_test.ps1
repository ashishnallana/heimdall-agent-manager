# Exercises the actual release packager, installer extraction and installation
# without touching host tasks, credentials or provider CLI configuration.
[CmdletBinding()]
param([string]$Bundle = '', [string]$Installer = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$root = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-extension-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Check([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  Write-Output "PASS: $Message"
}
function Fail([string]$Message) { throw $Message }
# Load only the installer's functions. Never run its host/service entry point.
$tokens = $null; $errors = $null
if (-not $Installer) { $Installer = Join-Path $repo 'scripts/install.ps1' }
$ast = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$errors)
Check ($errors.Count -eq 0) 'installer parses'
foreach ($name in @('Expand-HeimdallBundle', 'Assert-ProviderExtensionAssets', 'Install-ProviderExtensionAssets')) {
  $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  . ([scriptblock]::Create($definition.Extent.Text))
}
try {
  if (-not $Bundle) {
    $bin = Join-Path $root 'fake-bin'; New-Item -ItemType Directory $bin | Out-Null
    foreach ($name in @('ham-bridge.exe', 'ham-ctl.exe', 'ham-pty-host.exe')) {
      [IO.File]::WriteAllBytes((Join-Path $bin $name), [byte[]]@(0x4d, 0x5a, 0, 0))
    }
    & (Join-Path $repo 'scripts/release/package-windows-bundle.ps1') -BinDir $bin -Version vtest -OutDir $root
    $Bundle = Join-Path $root 'heimdall-local-windows-amd64.zip'
  }
  $extracted = Join-Path $root 'extracted'; New-Item -ItemType Directory $extracted | Out-Null
  Expand-HeimdallBundle $Bundle $extracted
  $source = Join-Path $extracted 'extensions'
  Assert-ProviderExtensionAssets $source
  Check (Test-Path -LiteralPath (Join-Path $source '.claude-plugin/marketplace.json')) 'Claude hidden marketplace extracted'
  Check (Test-Path -LiteralPath (Join-Path $source 'claude-code/.claude-plugin/plugin.json')) 'Claude hidden plugin manifest extracted'
  Check (Test-Path -LiteralPath (Join-Path $source '.agents/plugins/marketplace.json')) 'Codex hidden marketplace extracted'
  $hooks = Get-Content -LiteralPath (Join-Path $source 'antigravity/hooks.json') -Raw | ConvertFrom-Json
  Check ($null -ne $hooks.heimdall) 'Antigravity compatibility hooks contain JSON, not a symlink placeholder'
  $installedBin = Join-Path $root 'installed/bin'; New-Item -ItemType Directory -Force $installedBin | Out-Null
  Install-ProviderExtensionAssets $source $installedBin
  $installed = Join-Path $installedBin 'extensions'
  $stale = Join-Path $installed 'claude-code/removed-hook.json'
  [IO.File]::WriteAllText($stale, 'stale')
  $custom = Join-Path $root 'installed/extensions/custom.json'
  New-Item -ItemType Directory -Force (Split-Path -Parent $custom) | Out-Null
  [IO.File]::WriteAllText($custom, 'user override')
  Install-ProviderExtensionAssets $source $installedBin
  Check (-not (Test-Path -LiteralPath $stale)) 'reinstall replaces stale shipped assets'
  Check ((Get-Content -LiteralPath $custom -Raw) -eq 'user override') 'user extension overrides preserved'
  foreach ($asset in Get-ChildItem -LiteralPath $source -Recurse -Force -File) {
    $relative = $asset.FullName.Substring($source.Length + 1)
    Check ((Get-FileHash -LiteralPath $asset.FullName).Hash -eq (Get-FileHash -LiteralPath (Join-Path $installed $relative)).Hash) "installed asset matches bundle: $relative"
  }
  foreach ($unsafe in @('traversal', 'duplicate', 'symlink', 'stream')) {
    $badZip = Join-Path $root "$unsafe.zip"
    Copy-Item -LiteralPath $Bundle -Destination $badZip
    $z = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Update)
    try {
      $entryName = switch ($unsafe) {
        traversal { 'bin/extensions/../../escape.json' }
        duplicate { 'bin/extensions/.CLAUDE-PLUGIN/MARKETPLACE.JSON' }
        symlink { 'bin/extensions/linked.json' }
        stream { 'bin/extensions/manifest.json:stream' }
      }
      $entry = $z.CreateEntry($entryName)
      if ($unsafe -eq 'symlink') { $entry.ExternalAttributes = -1610612736 }
    } finally { $z.Dispose() }
    $badDestination = Join-Path $root "extract-$unsafe"
    New-Item -ItemType Directory $badDestination | Out-Null
    $rejected = $false
    try { Expand-HeimdallBundle $badZip $badDestination } catch { $rejected = $_.Exception.Message -like 'Unsafe*' }
    Check $rejected "unsafe $unsafe extension entry rejected"
  }
  Remove-Item -LiteralPath (Join-Path $source '.claude-plugin/marketplace.json')
  $rejected = $false
  try { Install-ProviderExtensionAssets $source $installedBin } catch { $rejected = $_.Exception.Message -like '*Incomplete provider extension bundle*' }
  Check $rejected 'incomplete extension generation rejected'
  Check (Test-Path -LiteralPath (Join-Path $installed '.claude-plugin/marketplace.json')) 'failed install preserves installed generation'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved) -ne ([IO.Path]::GetTempPath()).TrimEnd('\', '/') -or (Split-Path -Leaf $resolved) -notlike 'heimdall-extension-test-*') { throw "Unsafe test cleanup: $resolved" }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
