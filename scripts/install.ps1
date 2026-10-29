# Heimdall Bridge bootstrap for Windows (PowerShell 5.1 and 7, no admin rights):
#
#   irm install.ninjy.ai/ps1 | iex                       (flags via $env:HEIMDALL_HUB etc.)
#   & ([scriptblock]::Create((irm install.ninjy.ai/ps1))) -Hub https://<hub>
#
# It only resolves a release, downloads the windows-amd64 bundle, verifies it
# against the release's SHA256SUMS and runs `ham-bridge setup --headless` from it
# with the remaining options passed through. Installing, enrolling, the Scheduled
# Task, extensions and rollback all live in ham-bridge; updates use
# `ham-bridge update --version`. Self-contained: it makes no assumption about
# where it was fetched from (install.ninjy.ai, a release asset or main).
#
# Without arguments (the `| iex` form) these environment variables are read:
#   HEIMDALL_HUB, HEIMDALL_BRIDGE_NAME (profile), HEIMDALL_VERSION.
#
# Keep this file pure ASCII (Windows PowerShell 5.1 reads a BOM-less .ps1 as
# ANSI). Never call `exit` outside the bottom of the file: under the scriptblock
# one-liner that would close the operator's PowerShell window.
[CmdletBinding()]
param(
  [Alias('HubUrl')][string]$Hub = $env:HEIMDALL_HUB,
  [Alias('Profile')][string]$Name = $env:HEIMDALL_BRIDGE_NAME,
  [string]$Version = $env:HEIMDALL_VERSION,
  [string]$Bundle = '',
  [string]$ChecksumFile = '',
  [string]$ReuseBridge = '',
  [switch]$NewBridge,
  [switch]$JsonProgress,
  [switch]$Uninstall,
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$HeimdallRepo = 'tanmayv/heimdall-agent-manager'
$HeimdallTarget = 'windows-amd64'

function Invoke-HeimdallBootstrap {
  $ErrorActionPreference = 'Stop'
  if ($Help) {
    Write-Host @'
Usage: install.ps1 [-Version TAG|latest] [-Bundle ZIP -ChecksumFile FILE]
                   [-Hub URL] [-Name PROFILE] [-NewBridge | -ReuseBridge ID] [-JsonProgress]
                   [-Uninstall] [other ham-bridge flags, e.g. --yes]
Without -Version, installs the newest promoted (non-prerelease) release.
'@
    return 0
  }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $ProgressPreference = 'SilentlyContinue'
  $work = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-install-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $sums = Join-Path $work 'SHA256SUMS'
    if ($Bundle -or $ChecksumFile) {
      if (-not (Test-Path -PathType Leaf $Bundle) -or -not (Test-Path -PathType Leaf $ChecksumFile)) { throw '-Bundle and -ChecksumFile must both name files.' }
      $archive = Split-Path -Leaf $Bundle
      if ($archive -notlike "heimdall-local-$HeimdallTarget-*.zip") { throw "Bundle $archive is not a $HeimdallTarget bundle." }
      Copy-Item -LiteralPath $ChecksumFile $sums
      Copy-Item -LiteralPath $Bundle (Join-Path $work $archive)
    } else {
      $headers = @{ 'User-Agent' = 'heimdall-install.ps1'; 'Accept' = 'application/vnd.github+json' }
      if (-not $Version -or $Version -eq 'latest') {
        # Releases start as prereleases (canary candidates); only promoted ones are picked.
        $releases = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$HeimdallRepo/releases?per_page=30"
        $Version = $null
        foreach ($r in @($releases)) {
          $assets = @($r.assets | ForEach-Object { $_.name })
          if (-not $r.draft -and -not $r.prerelease -and ($assets -ccontains 'SHA256SUMS') -and ($assets -ccontains "heimdall-local-$HeimdallTarget-$($r.tag_name).zip")) { $Version = $r.tag_name; break }
        }
        if (-not $Version) { throw "No promoted release has a $HeimdallTarget bundle. Pass -Version TAG." }
      }
      if ($Version -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid release tag: $Version" }
      $archive = "heimdall-local-$HeimdallTarget-$Version.zip"
      $base = "https://github.com/$HeimdallRepo/releases/download/$Version"
      Write-Host "[INFO] Release $Version ($HeimdallTarget)"
      try { Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "$base/SHA256SUMS" -OutFile $sums } catch { throw "Release $Version has no SHA256SUMS (unknown tag?)." }
      Write-Host "[INFO] Downloading $archive"
      try { Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "$base/$archive" -OutFile (Join-Path $work $archive) } catch { throw "Release $Version has no $archive." }
    }
    # Exactly one SHA256SUMS entry for the bundle, and it must match.
    $expected = @(Get-Content -LiteralPath $sums | ForEach-Object { $f = @($_.Trim() -split '\s+'); if ($f.Count -eq 2 -and $f[1].TrimStart('*') -ceq $archive) { $f[0].ToLowerInvariant() } })
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $archive)).Hash.ToLowerInvariant()
    if ($expected.Count -ne 1 -or $expected[0] -ne $actual) { throw 'SHA-256 verification failed; nothing installed.' }
    Write-Host "[OK] SHA-256 verified: $archive"
    # ExtractToDirectory refuses entries that would land outside the destination.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dest = Join-Path $work 'bundle'
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $work $archive), $dest)
    $bridge = Join-Path (Join-Path $dest 'bin') 'ham-bridge.exe'
    if (-not (Test-Path -PathType Leaf $bridge)) { throw 'The bundle has no bin\ham-bridge.exe.' }

    $argv = @()
    if ($Uninstall) { $argv += 'uninstall' } else { $argv += @('setup', '--headless') }
    if ($Hub) { $argv += @('--hub', $Hub) }
    if ($Name) { $argv += @('--profile', $Name) }
    if (-not $Uninstall) {
      if ($NewBridge) { $argv += '--new-bridge' }
      if ($ReuseBridge) { $argv += @('--reuse-bridge', $ReuseBridge) }
    }
    if ($JsonProgress) { $argv += '--json-progress' }
    $argv += @($Rest)
    # ham-bridge copies what it needs out of the bundle; the temporary copy is removed below.
    & $bridge @argv
    return $LASTEXITCODE
  } catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    return 1
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
  }
}

$HeimdallExitCode = Invoke-HeimdallBootstrap
# Only a script file (-File) exits with the code; the scriptblock/iex forms leave
# it in $LASTEXITCODE so the operator's window stays open.
if ($MyInvocation.InvocationName -and $MyInvocation.MyCommand.Path) { exit $HeimdallExitCode }
$global:LASTEXITCODE = $HeimdallExitCode
