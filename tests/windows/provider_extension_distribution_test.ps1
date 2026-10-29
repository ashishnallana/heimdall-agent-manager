# Exercises the actual Windows release packager and checks that the ZIP carries
# every provider extension asset `ham-bridge setup` installs from
# share/heimdall/extensions (F10), without touching host tasks, credentials or
# provider CLI configuration. Installing/refreshing the assets is ham-bridge's
# job (src/bridge/extensions_cmd.odin and its tests).
[CmdletBinding()]
param([string]$Bundle = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$root = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-extension-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Check([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  Write-Output "PASS: $Message"
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
  $prefix = 'share/heimdall/extensions/'
  $z = [IO.Compression.ZipFile]::OpenRead($Bundle)
  try {
    $entries = @{}
    foreach ($e in $z.Entries) {
      $name = $e.FullName
      Check (-not $name.Contains('\')) "entry uses forward slashes: $name"
      if (-not $name.StartsWith($prefix)) { continue }
      $unixType = ([long]$e.ExternalAttributes -shr 16) -band 0xF000
      Check ($unixType -eq 0 -or $unixType -eq 0x8000) "extension entry is a regular file: $name"
      Check (-not $entries.ContainsKey($name.ToLowerInvariant())) "extension entry is unique: $name"
      $entries[$name.ToLowerInvariant()] = $e
    }
    foreach ($required in @(
      'antigravity/plugin.json', 'antigravity/hooks.json', 'antigravity/hooks/hooks.json',
      'claude-code/.claude-plugin/plugin.json', 'claude-code/hooks/hooks.json',
      'codex/.codex-plugin/plugin.json', 'codex/hooks/hooks.json',
      '.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'
    )) {
      Check $entries.ContainsKey(($prefix + $required).ToLowerInvariant()) "bundle carries $required"
    }
    $reader = [IO.StreamReader]::new($entries[($prefix + 'antigravity/hooks.json').ToLowerInvariant()].Open())
    try { $hooks = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    Check ($null -ne $hooks.heimdall) 'Antigravity compatibility hooks contain JSON, not a symlink placeholder'
  } finally { $z.Dispose() }
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $resolved) -ne ([IO.Path]::GetTempPath()).TrimEnd('\', '/') -or (Split-Path -Leaf $resolved) -notlike 'heimdall-extension-test-*') { throw "Unsafe test cleanup: $resolved" }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
