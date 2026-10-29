# scripts/apply-bridge-update.ps1
# Out-of-process supervisor for Heimdall Bridge binary replacement on Windows,
# with health-monitored automated rollback (REQ-BUPD-4, REQ-BUPD-5). The Windows
# twin of scripts/apply-bridge-update.sh: same --flags, caller interface,
# version hooks and log lines. Runs under Windows PowerShell 5.1, which the
# Bridge starts as (src/bridge/os_platform_windows.odin bridge_os_supervisor_argv):
#
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File apply-bridge-update.ps1 --flags...
#
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less script in the
# ANSI code page.
#
# Service model (scripts/install.ps1): a per-user Scheduled Task runs
# wscript.exe <data>\bin\bridge-service.js, a hidden loop that runs
# bin\bridge-run.cmd (ham-bridge.exe) and restarts it on a non-zero exit; a
# clean exit 0 (the Bridge's update hand-off) ends the loop. Those two files and
# the ham-ctl-<service>.cmd wrapper are installer-generated and live in bin\, so
# the binary swap carries them over.
#
# Dot-sourcing this file (. .\apply-bridge-update.ps1) defines its functions and
# returns before parsing any argument; tests use that to call them directly.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:IsWindowsHost = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:PathComparison = [StringComparison]::Ordinal
if ($script:IsWindowsHost) { $script:PathComparison = [StringComparison]::OrdinalIgnoreCase }

# --- Configuration & Defaults ------------------------------------------------
function Get-EnvDefault {
  param([string]$Name, [string]$Default = '')
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ($value) { return $value }
  return $Default
}

$script:DefaultDataDir = ''
if ($env:LOCALAPPDATA) { $script:DefaultDataDir = Join-Path $env:LOCALAPPDATA 'heimdall' }
elseif ($HOME) { $script:DefaultDataDir = Join-Path $HOME '.local/share/heimdall' }
$DATA_DIR = Get-EnvDefault 'DATA_DIR' $script:DefaultDataDir
$STAGE_DIR = Get-EnvDefault 'STAGE_DIR'
$BRIDGE_PORT = Get-EnvDefault 'BRIDGE_PORT' '49323'
$HUB_URL = Get-EnvDefault 'HUB_URL' 'http://127.0.0.1:8989'
$HEALTH_TIMEOUT = Get-EnvDefault 'HEALTH_TIMEOUT' '30'
$SERVICE_NAME = Get-EnvDefault 'SERVICE_NAME' (Get-EnvDefault 'HEIMDALL_BRIDGE_SERVICE_NAME')
$BRIDGE_PID = Get-EnvDefault 'BRIDGE_PID'
$PTY_HOST_SOCKET = Get-EnvDefault 'PTY_HOST_SOCKET'
$STOP_PTY_HOSTS_ONLY = $false
$RESTART_HOOK = Get-EnvDefault 'RESTART_HOOK'
$STOP_HOOK = Get-EnvDefault 'STOP_HOOK'
$HEALTH_URL = Get-EnvDefault 'HEALTH_URL'
$HEALTH_METHOD = Get-EnvDefault 'HEALTH_METHOD'
# Caller contract (see "Caller interface" in docs/SELF_HOSTING.md). Interface 1
# is the original argv; deployed Bridges send it without --interface or any
# version. Interface 2 callers also name the running and the target version.
$SUPPORTED_INTERFACE = 2
$INTERFACE = ''
$FROM_VERSION = ''
$TO_VERSION = ''
$script:LogFile = ''

# --- Logging -----------------------------------------------------------------
function Get-UtcStamp {
  return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Write-LogFile {
  param([string]$Line)
  if (-not $script:LogFile) { return }
  try { [IO.File]::AppendAllText($script:LogFile, $Line + [Environment]::NewLine) } catch { }
}

function log {
  param([string]$Message)
  $line = '[apply-bridge-update] [' + (Get-UtcStamp) + '] ' + $Message
  [Console]::Out.WriteLine($line)
  Write-LogFile $line
}

function log_err {
  param([string]$Message)
  $line = '[apply-bridge-update] [' + (Get-UtcStamp) + '] ERROR: ' + $Message
  [Console]::Error.WriteLine($line)
  Write-LogFile $line
}

# Usage errors exit 2 before anything is stopped, like the .sh.
function Exit-Usage {
  param([string]$Message)
  [Console]::Error.WriteLine($Message)
  exit 2
}

function Show-Usage {
  $lines = @(
    'Usage: apply-bridge-update.ps1 [options]',
    "  --interface N         Caller interface version (default 1; current callers send $SUPPORTED_INTERFACE).",
    "                        A newer interface than $SUPPORTED_INTERFACE is refused before any change.",
    '  --from-version VER    Version of the running bridge (required by interface 2;',
    '                        absent = legacy caller, the version-independent flow)',
    '  --to-version VER      Version being installed (required by interface 2)',
    '                        Version hooks run on these before anything is stopped or',
    '                        swapped. All three flags also apply to --stop-pty-hosts-only.',
    '  --data-dir DIR        Root data directory (default: %LOCALAPPDATA%\heimdall)',
    '  --stage-dir DIR       Staging directory containing extracted binaries',
    '  --bridge-port PORT    Port bridge listens on for health check (default: 49323)',
    '  --hub-url URL         Central Hub URL',
    '  --health-timeout SEC  Healthcheck probe timeout in seconds (default: 30)',
    '  --service-name NAME   Scheduled Task name (auto-detected by default)',
    '  --bridge-pid PID      Exact bridge process to stop',
    '  --pty-host-socket PATH  Bridge-owned PTY daemon socket',
    "  --stop-pty-hosts-only   Only clean up this bridge's PTY hosts",
    '  --already-detached    Accepted for parity with the .sh; nothing to detach from on Windows',
    '  --restart-hook PATH   Executable restart hook for isolated tests',
    '  --stop-hook PATH      Executable stop hook for isolated tests',
    '  --health-url URL      Explicit health URL override (optional)',
    '  --health-method METHOD  Probe method override (default: OPTIONS, or GET with --health-url)'
  )
  foreach ($l in $lines) { [Console]::Out.WriteLine($l) }
}

# --- Version comparison ------------------------------------------------------
# SemVer 2.0 precedence. A leading "v" is accepted and +build metadata is
# ignored, as SemVer requires. Same rules as semver_compare in the .sh.
$SEMVER_RE = '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

function Test-SemVer {
  param([string]$Version)
  return [regex]::IsMatch($Version, $SEMVER_RE)
}

# Compare one dot-separated identifier: -1, 0 or 1. Numbers compare by value
# (any length) and rank below alphanumeric identifiers, which compare in ASCII
# order.
function Compare-SemVerIdent {
  param([string]$A, [string]$B)
  $aNum = $A -match '^[0-9]+$'
  $bNum = $B -match '^[0-9]+$'
  if ($aNum -and $bNum) {
    $A = $A.TrimStart('0'); $B = $B.TrimStart('0')
    if ($A.Length -ne $B.Length) { if ($A.Length -lt $B.Length) { return -1 } else { return 1 } }
  } elseif ($aNum) { return -1 }
  elseif ($bNum) { return 1 }
  $c = [string]::CompareOrdinal($A, $B)
  if ($c -lt 0) { return -1 }
  if ($c -gt 0) { return 1 }
  return 0
}

# -1, 0 or 1 (A <, = or > B); $null when either side is not a SemVer version.
function Compare-SemVer {
  param([string]$A, [string]$B)
  if (-not (Test-SemVer $A) -or -not (Test-SemVer $B)) { return $null }
  $a = $A; $b = $B
  if ($a.StartsWith('v')) { $a = $a.Substring(1) }
  if ($b.StartsWith('v')) { $b = $b.Substring(1) }
  $a = $a.Split('+')[0]; $b = $b.Split('+')[0]
  $aPre = ''; $bPre = ''
  $i = $a.IndexOf('-'); if ($i -ge 0) { $aPre = $a.Substring($i + 1); $a = $a.Substring(0, $i) }
  $i = $b.IndexOf('-'); if ($i -ge 0) { $bPre = $b.Substring($i + 1); $b = $b.Substring(0, $i) }
  $aIds = $a.Split('.'); $bIds = $b.Split('.')
  for ($i = 0; $i -lt 3; $i++) {
    $c = Compare-SemVerIdent $aIds[$i] $bIds[$i]
    if ($c -ne 0) { return $c }
  }
  # A release ranks above any of its pre-releases.
  if (-not $aPre -or -not $bPre) {
    if ($aPre) { return -1 }
    if ($bPre) { return 1 }
    return 0
  }
  $aIds = $aPre.Split('.'); $bIds = $bPre.Split('.')
  for ($i = 0; $i -lt $aIds.Length -and $i -lt $bIds.Length; $i++) {
    $c = Compare-SemVerIdent $aIds[$i] $bIds[$i]
    if ($c -ne 0) { return $c }
  }
  # Equal so far: the longer identifier list ranks higher.
  return (Compare-SemVerIdent "$($aIds.Length)" "$($bIds.Length)")
}

# Range tests for version hooks; both are false for a non-SemVer version.
function Test-VersionBefore {
  param([string]$A, [string]$B)
  $c = Compare-SemVer $A $B
  return ($null -ne $c -and $c -lt 0)
}

function Test-VersionAtLeast {
  param([string]$A, [string]$B)
  $c = Compare-SemVer $A $B
  return ($null -ne $c -and $c -ge 0)
}

# --- Paths and processes -----------------------------------------------------
# Absolute, normalized path (no symlink resolution: GetFullPath only collapses
# . and .. and, on Windows, turns / into \). Trailing separators are dropped.
function Get-CanonicalPath {
  param([string]$Path)
  if (-not $Path) { return '' }
  if ($script:IsWindowsHost) { $Path = $Path.Replace('/', '\') }
  try { $full = [IO.Path]::GetFullPath($Path) } catch { return $Path }
  $root = [IO.Path]::GetPathRoot($full)
  while ($full.Length -gt $root.Length -and ($full.EndsWith('\') -or $full.EndsWith('/'))) { $full = $full.Substring(0, $full.Length - 1) }
  return $full
}

function Test-SamePath {
  param([string]$A, [string]$B)
  return [string]::Equals($A, $B, $script:PathComparison)
}

function Get-PathLeaf {
  param([string]$Path)
  $p = $Path.TrimEnd('\', '/')
  $i = $p.LastIndexOfAny([char[]]@('\', '/'))
  if ($i -ge 0) { return $p.Substring($i + 1) }
  return $p
}

function Get-PathParent {
  param([string]$Path)
  $p = $Path.TrimEnd('\', '/')
  $i = $p.LastIndexOfAny([char[]]@('\', '/'))
  if ($i -gt 0) { return $p.Substring(0, $i) }
  if ($i -eq 0) { return $p.Substring(0, 1) }
  return ''
}

# Split a Windows command line into argv with CommandLineToArgvW rules:
# whitespace separates words outside quotes; 2n backslashes before a quote are
# n backslashes and the quote toggles quoting, 2n+1 are n and a literal quote;
# "" inside quotes is a literal quote; other backslashes are literal.
function Split-CommandLine {
  param([string]$CommandLine)
  $argv = New-Object 'System.Collections.Generic.List[string]'
  if (-not $CommandLine) { return @() }
  $word = New-Object Text.StringBuilder
  $inQuotes = $false
  $started = $false
  $n = $CommandLine.Length
  $i = 0
  while ($i -lt $n) {
    $c = $CommandLine[$i]
    if ($c -eq '\') {
      $slashes = 0
      while ($i -lt $n -and $CommandLine[$i] -eq '\') { $slashes++; $i++ }
      if ($i -lt $n -and $CommandLine[$i] -eq '"') {
        [void]$word.Append('\', [int][Math]::Floor($slashes / 2))
        if ($slashes % 2 -eq 1) { [void]$word.Append('"'); $i++ }
      } else {
        [void]$word.Append('\', $slashes)
      }
      $started = $true
      continue
    }
    if ($c -eq '"') {
      if ($inQuotes -and ($i + 1) -lt $n -and $CommandLine[$i + 1] -eq '"') {
        [void]$word.Append('"'); $i += 2; continue
      }
      $inQuotes = -not $inQuotes
      $started = $true
      $i++
      continue
    }
    if (-not $inQuotes -and ($c -eq ' ' -or $c -eq "`t")) {
      if ($started) { $argv.Add($word.ToString()); [void]$word.Clear(); $started = $false }
      $i++
      continue
    }
    [void]$word.Append($c)
    $started = $true
    $i++
  }
  if ($started) { $argv.Add($word.ToString()) }
  return $argv.ToArray()
}

# Start time of a live process as UTC ticks: the identity checked before every
# signal, so a reused PID is never stopped. $null when the process is gone or
# its start time is not readable (another user's process).
function Get-ProcessBorn {
  param([int]$ProcessId)
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    $t = $p.StartTime
    if ($null -eq $t) { return $null }
    return [string]$t.ToUniversalTime().Ticks
  } catch { return $null }
}

# Start times of every visible process, keyed by PID, from one enumeration.
function Get-ProcessBornTable {
  $born = @{}
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    try {
      $t = $p.StartTime
      if ($null -ne $t) { $born[[int]$p.Id] = [string]$t.ToUniversalTime().Ticks }
    } catch { }
  }
  return $born
}

# The process readers return one record per live process owned by this user:
# Id, Parent, Born, Exe, CommandLine. "cim" (Win32_Process) is the Windows
# reader. "process" (Get-Process; PowerShell 7 only, which exposes CommandLine
# and Parent) covers hosts where CIM is broken and the Linux test runs.
# PTY_PROCESS_READER=cim|process forces one, like the .sh's procfs|ps override.
function Get-PtyProcessReader {
  $forced = Get-EnvDefault 'PTY_PROCESS_READER'
  if ($forced) { return $forced }
  if ($script:IsWindowsHost -and (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return 'cim' }
  if ((Get-Process -Id $PID).PSObject.Properties['CommandLine']) { return 'process' }
  return ''
}

function Get-CurrentUserSid {
  try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return '' }
}

function Read-ProcessesCim {
  $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  if ($all.Count -eq 0) { throw 'Win32_Process returned no processes' }
  # Get-Process start times are the identity both readers compare; a process
  # whose start time cannot be read belongs to another user and is skipped.
  $born = Get-ProcessBornTable
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in $all) {
    $id = [int]$p.ProcessId
    if ($id -eq 0 -or -not $born.ContainsKey($id)) { continue }
    $records.Add([pscustomobject]@{
        Id = $id; Parent = [int]$p.ParentProcessId; Born = $born[$id]
        Exe = "$($p.ExecutablePath)"; CommandLine = "$($p.CommandLine)"; Owner = $null; Cim = $p
      })
  }
  return ,$records.ToArray()
}

function Read-ProcessesGetProcess {
  $all = @(Get-Process -ErrorAction Stop)
  if ($all.Count -eq 0) { throw 'Get-Process returned no processes' }
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in $all) {
    try {
      $t = $p.StartTime
      if ($null -eq $t) { continue }
      $parent = 0
      try { if ($p.Parent) { $parent = [int]$p.Parent.Id } } catch { }
      $records.Add([pscustomobject]@{
          Id = [int]$p.Id; Parent = $parent; Born = [string]$t.ToUniversalTime().Ticks
          Exe = "$($p.Path)"; CommandLine = "$($p.CommandLine)"; Owner = $null; Cim = $null
        })
    } catch { }
  }
  return ,$records.ToArray()
}

# --- Bridge-owned PTY host cleanup -------------------------------------------
# Stop only this bridge's hosts, including hosts still running from bin.old,
# bin.bak or bin.failed, and their descendants. Process identities are captured
# before a daemon is asked to shut down: its children may otherwise be
# reparented and become invisible to cleanup.

# Decide which records are hosts this bridge owns: a ham-pty-host daemon/run
# whose binary is in this private installation's bin\ (or a swap directory), or
# one serving exactly this bridge's socket. Returns @{ Owned = pid set; Sockets }.
# Pure: callers pass the snapshot, the canonical data dir and expected socket.
function Select-OwnedPtyProcesses {
  param([object[]]$Records, [string]$DataDir, [string]$ExpectedSocket, [bool]$PrivateInstall)
  $owned = @{}
  $sockets = New-Object 'System.Collections.Generic.List[string]'
  $byId = @{}
  foreach ($r in $Records) { $byId[[int]$r.Id] = $r }
  foreach ($r in $Records) {
    $argv = @(Split-CommandLine $r.CommandLine)
    if ($argv.Count -eq 0) { continue }
    if (-not (@($argv | Where-Object { $_ -ceq 'daemon' -or $_ -ceq 'run' }).Count -gt 0)) { continue }
    # An interpreter can run a test/script host; release binaries use argv[0].
    $hosts = @()
    foreach ($h in @($r.Exe, $argv[0], $(if ($argv.Count -gt 1) { $argv[1] } else { '' }))) {
      if (-not $h) { continue }
      $leaf = Get-PathLeaf $h
      if ($leaf -ieq 'ham-pty-host' -or $leaf -ieq 'ham-pty-host.exe') { $hosts += $h }
    }
    if ($hosts.Count -eq 0) { continue }
    $socket = ''
    for ($i = 0; $i -lt $argv.Count; $i++) {
      if ($argv[$i] -ceq '--socket' -and ($i + 1) -lt $argv.Count) { $socket = $argv[$i + 1] }
      elseif ($argv[$i].StartsWith('--socket=')) { $socket = $argv[$i].Substring(9) }
    }
    $ownedBinary = $false
    if ($PrivateInstall) {
      foreach ($h in $hosts) {
        $parent = Get-PathParent $h
        if (@('bin', 'bin.old', 'bin.bak', 'bin.failed') -notcontains (Get-PathLeaf $parent).ToLowerInvariant()) { continue }
        if (Test-SamePath (Get-CanonicalPath (Get-PathParent $parent)) $DataDir) { $ownedBinary = $true }
      }
    }
    $ownedSocket = $false
    if ($ExpectedSocket -and $socket) { $ownedSocket = Test-SamePath (Get-CanonicalPath $socket) $ExpectedSocket }
    if ($ownedBinary -or $ownedSocket) {
      $owned[[int]$r.Id] = $true
      if ($socket) { $sockets.Add($socket) }
    }
  }
  # Descendants. Windows does not reparent orphans, so a ParentProcessId can name
  # a dead parent whose PID was reused: a child must not predate its parent.
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($r in $Records) {
      $id = [int]$r.Id
      if ($owned.ContainsKey($id) -or -not $owned.ContainsKey([int]$r.Parent)) { continue }
      $parent = $byId[[int]$r.Parent]
      if ($null -ne $parent -and [long]$r.Born -lt [long]$parent.Born) { continue }
      $owned[$id] = $true
      $changed = $true
    }
  }
  return @{ Owned = $owned; Sockets = @($sockets | Sort-Object -Unique) }
}

# Run a program for at most $Seconds, hidden, without a shell; kill it on timeout.
function Invoke-Bounded {
  param([int]$Seconds, [string]$FilePath, [string[]]$Arguments)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $quoted = foreach ($a in $Arguments) {
    if ($a -match '^[^\s"]+$') { $a } else { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }
  $psi.Arguments = ($quoted -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $p.StandardOutput.ReadToEndAsync() | Out-Null
  $p.StandardError.ReadToEndAsync() | Out-Null
  if (-not $p.WaitForExit($Seconds * 1000)) {
    try { $p.Kill() } catch { }
    return $false
  }
  return ($p.ExitCode -eq 0)
}

# The process is still the one captured in the snapshot (start time unchanged).
function Test-PtyAlive {
  param([int]$ProcessId)
  $born = Get-ProcessBorn $ProcessId
  return ($null -ne $born -and $born -eq $script:PtyBorn[$ProcessId])
}

function Test-PtyAnyAlive {
  foreach ($id in @($script:PtyOwned.Keys)) { if (Test-PtyAlive $id) { return $true } }
  return $false
}

function Wait-PtyStopped {
  param([double]$Seconds)
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ((Test-PtyAnyAlive) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
}

# Returns 0 when nothing owned is left running, 1 when processes survived (the
# swap is refused), 3 when processes could not be listed (nothing was stopped).
function Stop-PtyHosts {
  $reader = Get-PtyProcessReader
  $records = $null
  switch ($reader) {
    'cim' { try { $records = Read-ProcessesCim } catch { $records = $null } }
    'process' { try { $records = Read-ProcessesGetProcess } catch { $records = $null } }
    default {
      log_err 'Neither CIM (Win32_Process) nor Get-Process with command lines is available to find bridge-owned PTY hosts; no process was stopped'
      return 3
    }
  }
  if ($null -eq $records -or @($records).Count -eq 0) {
    log_err "Could not list processes through $reader to find bridge-owned PTY hosts; no process was stopped"
    return 3
  }
  $dataCanon = Get-CanonicalPath $DATA_DIR
  $expected = ''
  if ($PTY_HOST_SOCKET) { $expected = Get-CanonicalPath $PTY_HOST_SOCKET }
  $private = ((Get-PathLeaf (Get-PathParent $dataCanon)) -ieq 'bridges')
  $sel = Select-OwnedPtyProcesses -Records $records -DataDir $dataCanon -ExpectedSocket $expected -PrivateInstall $private
  $owned = $sel.Owned

  # The CIM reader lists every user's processes: keep only this user's.
  if ($reader -eq 'cim' -and $owned.Count -gt 0) {
    $me = Get-CurrentUserSid
    $byId = @{}
    foreach ($r in $records) { $byId[[int]$r.Id] = $r }
    foreach ($id in @($owned.Keys)) {
      $sid = ''
      try { $sid = "$((Invoke-CimMethod -InputObject $byId[$id].Cim -MethodName GetOwnerSid -ErrorAction Stop).Sid)" } catch { }
      if (-not $me -or $sid -ne $me) { $owned.Remove($id) }
    }
  }
  if ($owned.Count -eq 0) { return 0 }
  $script:PtyOwned = $owned
  $script:PtyBorn = @{}
  foreach ($r in $records) { if ($owned.ContainsKey([int]$r.Id)) { $script:PtyBorn[[int]$r.Id] = [string]$r.Born } }

  # Best effort protocol shutdown lets the PTY host terminate/reap its own agents.
  $client = Join-Path (Join-Path $dataCanon 'bin') 'ham-pty-host.exe'
  if (-not (Test-Path -LiteralPath $client -PathType Leaf)) { $client = Join-Path (Join-Path $dataCanon 'bin') 'ham-pty-host' }
  if ($sel.Sockets.Count -gt 0 -and (Test-Path -LiteralPath $client -PathType Leaf)) {
    foreach ($socket in $sel.Sockets) {
      try { [void](Invoke-Bounded 3 $client @('--socket', $socket, 'stop')) } catch { }
    }
  }

  $ids = @($owned.Keys | Sort-Object)
  log "stopping bridge-owned PTY processes: $($ids -join ', ') (found through $reader)"
  # Windows has no SIGTERM: the protocol stop above is the graceful step. Give
  # it the .sh's TERM grace, then terminate whatever is left.
  Wait-PtyStopped 3
  foreach ($id in $ids) {
    if (Test-PtyAlive $id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
  }
  Wait-PtyStopped 2
  if (Test-PtyAnyAlive) {
    log_err 'Bridge-owned PTY processes did not stop; refusing binary swap.'
    return 1
  }
  return 0
}

# --- Version hooks -----------------------------------------------------------
# The one place for release-specific update logic. The Bridge runs the staged
# (target) bundle's copy of this script, so a release can carry a fix for the
# Bridges it upgrades from. Hooks run before anything is stopped, cleaned up or
# swapped, in both modes (Phase is "update" or "stop-pty-hosts-only"). A hook
# that must abort calls log_err and exits non-zero, which leaves the running
# Bridge untouched. Match exact versions or wildcards on $FROM_VERSION and
# $TO_VERSION in the switch statements, and ranges with Test-VersionBefore /
# Test-VersionAtLeast (false for a non-SemVer version, so a range hook never
# fires on one), e.g.
#   if (Test-VersionBefore $FROM_VERSION '0.7.0') { Update-OldLayout }
# Legacy callers (Bridges that predate interface 2) send no versions and get no
# hooks: a fix they need belongs in the version-independent flow. Keep the
# hooks here in step with run_version_hooks in apply-bridge-update.sh.
function Invoke-VersionHooks {
  param([string]$Phase)
  if (-not $FROM_VERSION) {
    log "Legacy caller (interface $INTERFACE, no --from-version): $Phase runs the version-independent flow without version hooks"
    return
  }
  $to = $TO_VERSION
  if (-not $to) { $to = 'unknown' }
  log "Version hooks ($Phase): interface $INTERFACE, from $FROM_VERSION to $to"
  $cmp = $null
  if ($TO_VERSION) { $cmp = Compare-SemVer $FROM_VERSION $TO_VERSION }
  switch ($cmp) {
    -1 { log '  direction: upgrade' }
    0 { log '  direction: reinstall of the running version' }
    1 { log '  direction: downgrade' }
    default { log '  direction: unknown (a version is not SemVer); range hooks do not apply' }
  }

  switch -Wildcard -CaseSensitive ($FROM_VERSION) {
    '0.5.*' { log "  hook: from-version $FROM_VERSION (0.5 line): no compatibility steps required" }
    'v0.5.*' { log "  hook: from-version $FROM_VERSION (0.5 line): no compatibility steps required" }
  }

  # Hooks keyed on the version being installed go here.
  switch -Wildcard -CaseSensitive ($TO_VERSION) {
    default { }
  }
}

# --- Bridge service ----------------------------------------------------------
function Get-LauncherPath { return (Join-Path (Join-Path (Get-CanonicalPath $DATA_DIR) 'bin') 'bridge-service.js') }

# The hidden wscript loop of this data dir's task (install.ps1 Get-BridgeProcesses).
function Get-ServiceLoopProcesses {
  $launcher = Get-LauncherPath
  if (-not $script:IsWindowsHost) { return @() }
  return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue | Where-Object {
      $_.CommandLine -and $_.CommandLine.IndexOf($launcher, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

# Every process running from this data dir's bin\ (the bridge and anything it
# left behind), as install.ps1 matches them.
function Get-BinProcesses {
  if (-not $script:IsWindowsHost) { return @() }
  $prefix = (Join-Path (Get-CanonicalPath $DATA_DIR) 'bin') + '\'
  return @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

# Find the Scheduled Task whose action runs this data dir's bridge-service.js;
# refuses to guess between several. Returns '' when there is none.
function Find-BridgeService {
  if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return '' }
  $launcher = Get-LauncherPath
  $found = @()
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    foreach ($a in @($t.Actions)) {
      $line = "$($a.Execute) $($a.Arguments)"
      if ($line.IndexOf($launcher, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found += $t; break }
    }
  }
  if ($found.Count -gt 1) {
    log_err 'Multiple services reference this bridge; specify --service-name.'
    exit 1
  }
  if ($found.Count -eq 1) {
    if ($found[0].TaskPath -ne '\') { return ($found[0].TaskPath + $found[0].TaskName) }
    return $found[0].TaskName
  }
  return ''
}

function Get-TaskParts {
  param([string]$Name)
  $i = $Name.LastIndexOf('\')
  if ($i -lt 0) { return @('\', $Name) }
  return @($Name.Substring(0, $i + 1), $Name.Substring($i + 1))
}

function Get-BridgeTask {
  $parts = Get-TaskParts $SERVICE_NAME
  return (Get-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction SilentlyContinue)
}

function Invoke-Hook {
  param([string]$Hook, [string[]]$Arguments, [string]$Kind)
  if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) { log_err "$Kind hook is not executable: $Hook"; return $false }
  & $Hook @Arguments
  return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
}

function Test-BridgePidRunning {
  param([int]$ProcessId, [string]$Born)
  $now = Get-ProcessBorn $ProcessId
  return ($null -ne $now -and $now -eq $Born)
}

# End the service loop without asking Task Scheduler: Stop-ScheduledTask ends
# the whole task, and this supervisor, started by the bridge, may belong to it.
# With the loop gone nothing restarts the bridge while bin\ is swapped.
function Stop-ServiceLoop {
  foreach ($p in @(Get-ServiceLoopProcesses)) {
    log "Stopping service loop wscript.exe PID $($p.ProcessId)"
    Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
  }
}

function Wait-ProcessesGone {
  param([scriptblock]$Query, [int]$Seconds)
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while (@(& $Query).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
  return (@(& $Query).Count -eq 0)
}

function Stop-BridgeService {
  log 'Stopping active bridge service...'
  if ($STOP_HOOK) {
    return (Invoke-Hook $STOP_HOOK @("$BRIDGE_PID") 'Stop')
  }
  if ($BRIDGE_PID -match '^[1-9][0-9]*$') {
    $bridgePid = [int]$BRIDGE_PID
    $born = Get-ProcessBorn $bridgePid
    Stop-ServiceLoop
    if ($null -eq $born) { return $true }
    # The bridge exits 0 by itself shortly after handing off to this script.
    # Windows has no SIGTERM: wait for that exit, then terminate the exact PID.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Test-BridgePidRunning $bridgePid $born) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (Test-BridgePidRunning $bridgePid $born) {
      log "Bridge PID $bridgePid did not exit on its own; terminating it"
      Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
      $deadline = [DateTime]::UtcNow.AddSeconds(5)
      while ((Test-BridgePidRunning $bridgePid $born) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    }
    if (Test-BridgePidRunning $bridgePid $born) {
      log_err "Bridge PID $bridgePid did not exit after it was terminated"
      return $false
    }
    return $true
  }
  if ($SERVICE_NAME) {
    # Not started by the bridge (an operator run): ending the task is safe here.
    $parts = Get-TaskParts $SERVICE_NAME
    Stop-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction SilentlyContinue
    Stop-ServiceLoop
    $bridgeExe = Join-Path (Join-Path (Get-CanonicalPath $DATA_DIR) 'bin') 'ham-bridge.exe'
    $query = { @(Get-BinProcesses | Where-Object { $_.ExecutablePath -ieq $bridgeExe }) }
    if (-not (Wait-ProcessesGone $query 10)) {
      foreach ($p in @(& $query)) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
      if (-not (Wait-ProcessesGone $query 5)) { log_err "ham-bridge.exe under $DATA_DIR\bin did not stop"; return $false }
    }
    return $true
  }
  log_err 'No scoped bridge stop mechanism is available'
  return $false
}

# Rollback runs after the new bridge was started under an unknown PID: stop the
# loop and everything running from this data dir's bin\, which must be idle
# before the directory can be renamed.
function Stop-BridgeForRollback {
  if ($STOP_HOOK) {
    return (Invoke-Hook $STOP_HOOK @("$BRIDGE_PID") 'Stop')
  }
  Stop-ServiceLoop
  $query = { @(Get-BinProcesses) }
  foreach ($p in @(& $query)) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
  if (-not (Wait-ProcessesGone $query 10)) { log_err "Processes under $DATA_DIR\bin did not stop"; return $false }
  return $true
}

function Start-BridgeService {
  log 'Starting bridge service...'
  if ($RESTART_HOOK) {
    return (Invoke-Hook $RESTART_HOOK @() 'Restart')
  }
  $dataCanon = Get-CanonicalPath $DATA_DIR
  if ($SERVICE_NAME) {
    $parts = Get-TaskParts $SERVICE_NAME
    # IgnoreNew: a start while the task still counts as running is dropped.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
      $t = Get-BridgeTask
      if ($null -eq $t -or "$($t.State)" -ne 'Running') { break }
      Start-Sleep -Milliseconds 200
    }
    try {
      Start-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction Stop
      return $true
    } catch {
      log_err "Start-ScheduledTask $SERVICE_NAME failed: $($_.Exception.Message)"
      return $false
    }
  }
  $launcher = Get-LauncherPath
  $bridgeExe = Join-Path (Join-Path $dataCanon 'bin') 'ham-bridge.exe'
  try {
    if ($script:IsWindowsHost -and (Test-Path -LiteralPath $launcher -PathType Leaf)) {
      $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
      Start-Process -FilePath $wscript -ArgumentList @('//B', '//NoLogo', "`"$launcher`"") -WorkingDirectory $dataCanon | Out-Null
      return $true
    }
    if (Test-Path -LiteralPath $bridgeExe -PathType Leaf) {
      Start-Process -FilePath $bridgeExe -WorkingDirectory $dataCanon -WindowStyle Hidden | Out-Null
      return $true
    }
  } catch {
    log_err "Could not start the bridge: $($_.Exception.Message)"
    return $false
  }
  log_err 'No start mechanism found for bridge'
  return $false
}

# --- Binary swap -------------------------------------------------------------
# Rename a directory, retrying briefly: antivirus scanners and the indexer hold
# short-lived handles that make a rename fail with a sharing violation.
function Rename-DirectoryWithRetry {
  param([string]$From, [string]$To)
  for ($i = 0; ; $i++) {
    try { [IO.Directory]::Move($From, $To); return } catch {
      if ($i -ge 20) { throw }
      Start-Sleep -Milliseconds 250
    }
  }
}

function Remove-DirectoryIfPresent {
  param([string]$Path)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Copy-DirectoryContents {
  param([string]$From, [string]$To)
  New-Item -ItemType Directory -Force -Path $To | Out-Null
  foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $To -Recurse -Force
  }
}

# Installer-generated files in bin\ (install.ps1: the service loop, its .cmd,
# the per-Hub ham-ctl wrapper) are installation-specific, not release binaries.
function Test-InstallerFile {
  param([string]$Name)
  return ($Name -like 'ham-ctl-*' -or $Name -ieq 'bridge-service.js' -or $Name -ieq 'bridge-run.cmd')
}

# --- Health ------------------------------------------------------------------
function Get-HealthStatus {
  try {
    $req = [Net.HttpWebRequest]::Create($HEALTH_URL)
    $req.Method = $HEALTH_METHOD
    $req.Timeout = 3000
    $req.ReadWriteTimeout = 3000
    $req.Proxy = $null
    $resp = $req.GetResponse()
    try { return [int]$resp.StatusCode } finally { $resp.Close() }
  } catch [Net.WebException] {
    if ($_.Exception.Response) {
      try { return [int]$_.Exception.Response.StatusCode } finally { $_.Exception.Response.Close() }
    }
    return 0
  } catch {
    return 0
  }
}

# Defining functions only: a dot-sourcing test stops here.
if ($MyInvocation.InvocationName -eq '.') { return }

# --- Arguments -----------------------------------------------------------------
$argv = @($args)
$i = 0
function Get-FlagValue {
  param([string]$Flag)
  if (($script:i + 1) -ge $script:argv.Count) { Exit-Usage "Missing value for $Flag" }
  $script:i += 2
  return [string]$script:argv[$script:i - 1]
}
while ($i -lt $argv.Count) {
  $flag = [string]$argv[$i]
  switch -CaseSensitive ($flag) {
    '--interface' { $INTERFACE = Get-FlagValue $flag; break }
    '--from-version' { $FROM_VERSION = Get-FlagValue $flag; break }
    '--to-version' { $TO_VERSION = Get-FlagValue $flag; break }
    '--data-dir' { $DATA_DIR = Get-FlagValue $flag; break }
    '--stage-dir' { $STAGE_DIR = Get-FlagValue $flag; break }
    '--bridge-port' { $BRIDGE_PORT = Get-FlagValue $flag; break }
    '--hub-url' { $HUB_URL = Get-FlagValue $flag; break }
    '--health-timeout' { $HEALTH_TIMEOUT = Get-FlagValue $flag; break }
    '--service-name' { $SERVICE_NAME = Get-FlagValue $flag; break }
    '--bridge-pid' { $BRIDGE_PID = Get-FlagValue $flag; break }
    '--stop-pty-hosts-only' { $STOP_PTY_HOSTS_ONLY = $true; $i++; break }
    '--already-detached' { $i++; break }
    '--pty-host-socket' { $PTY_HOST_SOCKET = Get-FlagValue $flag; break }
    '--restart-hook' { $RESTART_HOOK = Get-FlagValue $flag; break }
    '--stop-hook' { $STOP_HOOK = Get-FlagValue $flag; break }
    '--health-url' { $HEALTH_URL = Get-FlagValue $flag; break }
    '--health-method' { $HEALTH_METHOD = Get-FlagValue $flag; break }
    { $_ -ceq '-h' -or $_ -ceq '--help' } { Show-Usage; exit 0 }
    default { Exit-Usage "Unknown flag: $flag" }
  }
}

# Expand a leading ~ like the .sh.
$homeDir = $HOME
if (-not $homeDir) { $homeDir = $env:USERPROFILE }
if ($DATA_DIR -match '^~(?=$|[\\/])') { $DATA_DIR = $homeDir + $DATA_DIR.Substring(1) }
if (-not $STAGE_DIR) { $STAGE_DIR = Join-Path (Join-Path $DATA_DIR 'updates') 'stage' }
if ($STAGE_DIR -match '^~(?=$|[\\/])') { $STAGE_DIR = $homeDir + $STAGE_DIR.Substring(1) }

if (-not $HEALTH_URL) {
  $HEALTH_URL = "http://127.0.0.1:$BRIDGE_PORT/bridge/health"
  if (-not $HEALTH_METHOD) { $HEALTH_METHOD = 'OPTIONS' }
} elseif (-not $HEALTH_METHOD) {
  $HEALTH_METHOD = 'GET'
}
if (@('GET', 'OPTIONS') -cnotcontains $HEALTH_METHOD) {
  Exit-Usage "Unsupported health method: $HEALTH_METHOD (expected GET or OPTIONS)"
}
if ($HEALTH_TIMEOUT -notmatch '^[0-9]+$') { Exit-Usage "Invalid --health-timeout value: $HEALTH_TIMEOUT (expected seconds)" }

# Validate the caller contract before anything is stopped, cleaned up or swapped.
if (-not $INTERFACE) {
  $INTERFACE = '1'
} elseif ($INTERFACE -cnotmatch '^[1-9][0-9]{0,8}$') {
  Exit-Usage "Invalid --interface value: $INTERFACE (expected a positive integer)"
} elseif ([int]$INTERFACE -gt $SUPPORTED_INTERFACE) {
  Exit-Usage "Unsupported supervisor interface ${INTERFACE}: this apply-bridge-update.ps1 supports interfaces 1-$SUPPORTED_INTERFACE; refusing before any change"
}
if ([int]$INTERFACE -ge 2 -and (-not $FROM_VERSION -or -not $TO_VERSION)) {
  Exit-Usage "Supervisor interface $INTERFACE requires --from-version and --to-version"
}

if ($STOP_PTY_HOSTS_ONLY) {
  Invoke-VersionHooks 'stop-pty-hosts-only'
  exit (Stop-PtyHosts)
}

# The bridge does not capture this run's output: keep a log next to the bridge's.
try {
  $logDir = Join-Path (Get-CanonicalPath $DATA_DIR) 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $script:LogFile = Join-Path $logDir 'apply-bridge-update.log'
} catch { $script:LogFile = '' }

$BIN = Join-Path (Get-CanonicalPath $DATA_DIR) 'bin'
$BIN_BAK = "$BIN.bak"
$BIN_NEW = "$BIN.new"
$BIN_OLD = "$BIN.old"
$BIN_FAILED = "$BIN.failed"

try {
  log 'Starting supervisor execution'
  log "  INTERFACE:      $INTERFACE"
  $shownFrom = $FROM_VERSION; if (-not $shownFrom) { $shownFrom = 'unset (legacy caller)' }
  $shownTo = $TO_VERSION; if (-not $shownTo) { $shownTo = 'unset' }
  $shownPid = $BRIDGE_PID; if (-not $shownPid) { $shownPid = 'unset' }
  log "  FROM_VERSION:   $shownFrom"
  log "  TO_VERSION:     $shownTo"
  log "  DATA_DIR:       $DATA_DIR"
  log "  STAGE_DIR:      $STAGE_DIR"
  log "  BRIDGE_PORT:    $BRIDGE_PORT"
  log "  HEALTH_URL:     $HEALTH_URL"
  log "  HEALTH_METHOD:  $HEALTH_METHOD"
  log "  HEALTH_TIMEOUT: ${HEALTH_TIMEOUT}s"
  log "  BRIDGE_PID:     $shownPid"
  log "  SUPERVISOR_PID: $PID (PowerShell $($PSVersionTable.PSVersion))"

  Invoke-VersionHooks 'update'

  # Locate staged binaries
  $STAGE_BIN = ''
  $STAGE_ROOT = $STAGE_DIR
  $hasBridge = { param($d) (Test-Path -LiteralPath (Join-Path $d 'ham-bridge.exe') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $d 'ham-bridge') -PathType Leaf) }
  if (Test-Path -LiteralPath (Join-Path $STAGE_DIR 'bin') -PathType Container) {
    $STAGE_BIN = Join-Path $STAGE_DIR 'bin'
  } elseif (Test-Path -LiteralPath (Join-Path $STAGE_DIR 'extract\bin') -PathType Container) {
    $STAGE_ROOT = Join-Path $STAGE_DIR 'extract'
    $STAGE_BIN = Join-Path $STAGE_ROOT 'bin'
  } elseif (Test-Path -LiteralPath (Join-Path $STAGE_DIR 'heimdall-cloudtop\bin') -PathType Container) {
    $STAGE_ROOT = Join-Path $STAGE_DIR 'heimdall-cloudtop'
    $STAGE_BIN = Join-Path $STAGE_ROOT 'bin'
  } elseif (& $hasBridge $STAGE_DIR) {
    $STAGE_BIN = $STAGE_DIR
  } else {
    log_err "Staged binaries not found in $STAGE_DIR"
    exit 1
  }

  log "Located staged binaries at: $STAGE_BIN"
  foreach ($binary in @('ham-bridge', 'ham-ctl', 'heimdall', 'ham-pty-host')) {
    foreach ($name in @("$binary.exe", $binary)) {
      if ((Test-Path -LiteralPath (Join-Path $BIN $name) -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $STAGE_BIN $name) -PathType Leaf)) {
        log_err "Update bundle is missing installed binary: $name"
        exit 1
      }
    }
  }
  # Provider extensions are copied and registered by `ham-bridge extensions sync`
  # once the new bridge is healthy (F10).
  $EXTENSION_SOURCE = ''
  foreach ($candidate in @('..\share\heimdall\extensions', '..\share\extensions', '..\extensions')) {
    if (Test-Path -LiteralPath (Join-Path $STAGE_BIN $candidate) -PathType Container) {
      $EXTENSION_SOURCE = (Resolve-Path -LiteralPath (Join-Path $STAGE_BIN $candidate)).Path
      log "  Provider extensions in the bundle: $EXTENSION_SOURCE"
      break
    }
  }

  # Resolve the owning Scheduled Task before stopping the bridge. The task's
  # bridge-run.cmd exports HEIMDALL_BRIDGE_SERVICE_NAME, which the bridge passes
  # on; otherwise match the task that runs this data dir's bridge-service.js.
  if (-not $SERVICE_NAME -and -not $RESTART_HOOK) { $SERVICE_NAME = Find-BridgeService }
  $shownService = $SERVICE_NAME; if (-not $shownService) { $shownService = 'standalone' }
  log "  SERVICE_NAME:   $shownService"

  # Fail before stopping or replacing anything if an explicitly managed service
  # cannot be found. Never relaunch its binary without its config and credentials.
  if ($SERVICE_NAME -and -not $RESTART_HOOK) {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) -or $null -eq (Get-BridgeTask)) {
      log_err "Managed service not found: $SERVICE_NAME"
      exit 1
    }
  }

  # 1. Stop current service cleanly
  if (-not (Stop-BridgeService)) {
    log_err 'Failed to stop bridge through a scoped mechanism'
    exit 1
  }

  $ptyStatus = Stop-PtyHosts
  if ($ptyStatus -ne 0) {
    # Nothing was swapped: bring the untouched bridge back rather than leave it down.
    log 'Restarting the unchanged bridge...'
    [void](Start-BridgeService)
    exit 1
  }

  # 2. Backup existing binaries
  log "Backing up current bin to $BIN_BAK"
  Remove-DirectoryIfPresent $BIN_BAK
  if (Test-Path -LiteralPath $BIN -PathType Container) { Copy-DirectoryContents $BIN $BIN_BAK }

  # 3. Replace binaries with one directory rename
  log "Staging new binaries into $BIN_NEW"
  Remove-DirectoryIfPresent $BIN_NEW
  Copy-DirectoryContents $STAGE_BIN $BIN_NEW
  if (Test-Path -LiteralPath $BIN -PathType Container) {
    foreach ($f in @(Get-ChildItem -LiteralPath $BIN -File -Force)) {
      if ((Test-InstallerFile $f.Name) -and -not (Test-Path -LiteralPath (Join-Path $BIN_NEW $f.Name))) {
        Copy-Item -LiteralPath $f.FullName -Destination $BIN_NEW -Force
      }
    }
  }

  # Copy migrations or assets if staged
  $stageMigrations = Join-Path $STAGE_DIR 'share\migrations'
  if (Test-Path -LiteralPath $stageMigrations -PathType Container) {
    Copy-DirectoryContents $stageMigrations (Join-Path (Get-CanonicalPath $DATA_DIR) 'share\migrations')
  }

  log "Performing directory swap into $BIN"
  Remove-DirectoryIfPresent $BIN_OLD
  $swapped = $false
  try {
    if (Test-Path -LiteralPath $BIN -PathType Container) { Rename-DirectoryWithRetry $BIN $BIN_OLD }
    try {
      Rename-DirectoryWithRetry $BIN_NEW $BIN
      $swapped = $true
    } catch {
      if (Test-Path -LiteralPath $BIN_OLD -PathType Container) { Rename-DirectoryWithRetry $BIN_OLD $BIN }
      throw
    }
  } catch {
    log_err "Directory swap failed: $($_.Exception.Message); the installed binaries are unchanged"
    Remove-DirectoryIfPresent $BIN_NEW
    log 'Restarting the unchanged bridge...'
    [void](Start-BridgeService)
    exit 1
  }
  try { Remove-DirectoryIfPresent $BIN_OLD } catch { log "  could not remove ${BIN_OLD}: $($_.Exception.Message)" }

  # 4. Restart service
  if (-not (Start-BridgeService)) {
    log_err 'Failed to restart bridge service'
  }

  # 5. Verification Gate: Poll health endpoint for up to HEALTH_TIMEOUT seconds
  log "Beginning health check polling for up to $HEALTH_TIMEOUT seconds..."
  $deadline = [DateTime]::UtcNow.AddSeconds([int]$HEALTH_TIMEOUT)
  $healthy = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    $code = Get-HealthStatus
    if ($code -eq 200) {
      $healthy = $true
      log "Health check succeeded (HTTP code: $code)"
      break
    }
    Start-Sleep -Seconds 1
  }

  # 6. Finalize or Rollback
  if ($healthy) {
    log 'Update verification succeeded! Removing backup and staging directory.'
    # Best effort: the bridge is healthy, and the Hub can retry a provider.
    $syncExe = Join-Path $BIN 'ham-bridge.exe'
    if ($EXTENSION_SOURCE -and (Test-Path -LiteralPath $syncExe -PathType Leaf)) {
      log "Syncing provider extensions from $EXTENSION_SOURCE"
      try {
        & $syncExe extensions sync --data-dir (Get-CanonicalPath $DATA_DIR) --source $EXTENSION_SOURCE 2>&1 | ForEach-Object { log "  $_" }
      } catch { log "  provider extension sync failed: $($_.Exception.Message)" }
    }
    Remove-DirectoryIfPresent $BIN_BAK
    Remove-DirectoryIfPresent $STAGE_DIR
    log 'Bridge update completed successfully.'
    exit 0
  }

  log_err "Health check timed out or failed after ${HEALTH_TIMEOUT}s! Initiating automatic rollback..."
  [void](Stop-BridgeForRollback)
  [void](Stop-PtyHosts)

  if (Test-Path -LiteralPath $BIN_BAK -PathType Container) {
    log "Restoring binaries from $BIN_BAK..."
    Remove-DirectoryIfPresent $BIN_FAILED
    if (Test-Path -LiteralPath $BIN -PathType Container) { Rename-DirectoryWithRetry $BIN $BIN_FAILED }
    Copy-DirectoryContents $BIN_BAK $BIN
    Remove-DirectoryIfPresent $BIN_FAILED
  } else {
    log_err "No $BIN_BAK found to restore from!"
  }

  log 'Restarting rolled-back service...'
  [void](Start-BridgeService)

  $logDir = Join-Path (Get-CanonicalPath $DATA_DIR) 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $rollbackLog = Join-Path $logDir 'update_rollback.log'
  [IO.File]::AppendAllText($rollbackLog, "Update failed: Health check timed out or failed after ${HEALTH_TIMEOUT}s on $(Get-UtcStamp)" + [Environment]::NewLine)
  log_err "Rollback complete. Log written to $rollbackLog"
  exit 1
} catch {
  log_err "Supervisor failed: $($_.Exception.Message)"
  exit 1
}
