# Heimdall Bridge installer for Windows: one per-user Scheduled Task per Hub.
# Windows twin of scripts/install.sh (same steps, Hub naming and release checks).
# Windows PowerShell 5.1 and PowerShell 7; no administrator rights needed.
#
# One-liner (no execution-policy change needed; nothing runs from a .ps1 file):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.ps1))) -Hub https://<hub>
# Once a Hub serves this file at /public/install.ps1, the same form works with
# that URL (see the pinned tokens below).
# From a checkout:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Hub https://<hub>
#
# Keep this file pure ASCII: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.
# Never call `exit` outside the bottom of the file: under the scriptblock one-liner
# that would close the operator's PowerShell window.
[CmdletBinding()]
param(
  [Alias('HubUrl')][string]$Hub = '',
  [string]$Version = '',
  [switch]$DryRun,
  [switch]$Uninstall,
  [switch]$ReEnroll,
  [switch]$KeepEnrollment,
  [switch]$NonInteractive,
  [switch]$Help,
  [string]$FromDir = ''
)

# A Hub that serves this script at /public/install.ps1 substitutes these two
# quoted tokens with its own origin and pinned release tag (the same pin its
# /public/install.sh carries), so `irm <hub>/public/install.ps1 | iex` works
# without arguments. Unsubstituted they still start with @@ and mean "none".
$HeimdallPinnedHub = '@@HEIMDALL_HUB@@'
$HeimdallPinnedVersion = '@@HEIMDALL_VERSION@@'

$HeimdallRepoApi = 'https://api.github.com/repos/tanmayv/heimdall-agent-manager/releases?per_page=30'
$HeimdallRepoDownload = 'https://github.com/tanmayv/heimdall-agent-manager/releases/download'
$HeimdallTarget = 'windows-amd64'
$HeimdallHubTimeoutSeconds = 20

function Show-HeimdallUsage {
  param()
  Write-Host @'
Heimdall Bridge installer - Windows (per-user Scheduled Task)
Usage: install.ps1 [-Hub URL] [-Version TAG] [-DryRun] [-Uninstall]
                   [-ReEnroll | -KeepEnrollment] [-NonInteractive] [-FromDir DIR]
Hub must be an HTTP(S) origin, e.g. https://hub.mundus.in or http://localhost:8080.
Without -Hub, asks on the terminal. Existing enrollment prompts before re-enrolling.
-NonInteractive preserves existing enrollment and prints a command for new enrollment.
-Uninstall removes only this Hub's task and binaries; credentials/data are kept.
-FromDir installs ham-bridge.exe, ham-pty-host.exe and ham-ctl.exe from a local
build (DIR or DIR\bin) instead of a GitHub release; no download or checksum.
The Hub is checked first (20 s budget, exact failure reason). Verified release
bundles are cached in %LOCALAPPDATA%\heimdall\cache\releases and reused when
their SHA-256 still matches the release's SHA256SUMS.
Config/token: %APPDATA%\heimdall\bridges\<service>; binaries, data and logs:
%LOCALAPPDATA%\heimdall\bridges\<service>. Both are readable by you only.
Run as your normal Windows user; no administrator rights are needed.
One-liner: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.ps1))) -Hub https://<hub>
'@
}

# Output style, mirroring install.sh. Colour only on a terminal (stdout not
# redirected), without NO_COLOR (https://no-color.org: any non-empty value);
# progress ticks and the progress bar only on a console stderr.
# HEIMDALL_INSTALL_PLAIN=1 turns off both.
$HeimdallStepTotal = 9

function Test-HeimdallColour {
  param()
  if ($env:HEIMDALL_INSTALL_PLAIN -eq '1' -or $env:NO_COLOR) { return $false }
  try { return -not [Console]::IsOutputRedirected } catch { return $false }
}

function Test-ConsoleOutput {
  param()
  if ($env:HEIMDALL_INSTALL_PLAIN -eq '1') { return $false }
  try { return ($Host.Name -eq 'ConsoleHost') -and (-not [Console]::IsErrorRedirected) } catch { return $false }
}

function Format-Elapsed {
  param([double]$Seconds)
  $s = [int]$Seconds
  if ($s -ge 60) { return ('{0}m{1:00}s' -f [int][math]::Floor($s / 60), ($s % 60)) }
  return "${s}s"
}

# A self-erasing "label... Ns" line on a console stderr; nothing otherwise.
function Write-Tick {
  param([string]$Label, [Diagnostics.Stopwatch]$Watch)
  if (Test-ConsoleOutput) { [Console]::Error.Write(("`r  {0}... {1} " -f $Label, (Format-Elapsed $Watch.Elapsed.TotalSeconds))) }
}

function Clear-Tick {
  param()
  if (Test-ConsoleOutput) { [Console]::Error.Write("`r" + (' ' * 60) + "`r") }
}

function Write-Log {
  param([string]$Level, [string]$Message)
  $colour = $null
  switch ($Level) { 'OK' { $colour = 'Green' } 'WARN' { $colour = 'Yellow' } 'ERROR' { $colour = 'Red' } }
  if ($colour -and (Test-HeimdallColour)) {
    Write-Host "[$Level]" -ForegroundColor $colour -NoNewline
    Write-Host " $Message"
  } else {
    Write-Host "[$Level] $Message"
  }
}

# Write-Step N TITLE: the "[N/9] TITLE" heading of one of the installer's steps;
# an empty N prints TITLE alone (the dry-run plan).
function Write-Step {
  param([string]$Number, [string]$Title)
  Write-Host ''
  if (-not $Number) { $prefix = '' } else { $prefix = "[$Number/$HeimdallStepTotal] " }
  if ($prefix -and (Test-HeimdallColour)) {
    Write-Host $prefix -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White
  } else {
    Write-Host "$prefix$Title"
  }
}

# A box with a cyan border on a colour terminal; plain lines otherwise. ASCII
# only, so the box is safe in any console code page.
function Write-Banner {
  param([string]$Version, [string]$HubUrl)
  $title = 'Heimdall Bridge Installer'
  $tagline = 'Your agents, connected locally'
  if (-not $Version) { $Version = 'latest release' }
  if (-not $HubUrl) { $HubUrl = 'asked below' }
  $info = @("Version  $Version", "Hub      $HubUrl")
  Write-Host ''
  if (-not (Test-HeimdallColour)) {
    Write-Host "$title - $tagline"
    foreach ($l in $info) { Write-Host "  $l" }
    return
  }
  $width = $tagline.Length
  foreach ($l in $info) { if ($l.Length -gt $width) { $width = $l.Length } }
  $rule = '+' + ('-' * ($width + 4)) + '+'
  Write-Host $rule -ForegroundColor Cyan
  foreach ($row in @(@($title, 'White'), @($tagline, 'DarkGray'), @('', 'Gray')) + @($info | ForEach-Object { , @($_, 'DarkGray') })) {
    Write-Host '|' -ForegroundColor Cyan -NoNewline
    Write-Host ('  ' + $row[0].PadRight($width) + '  ') -ForegroundColor $row[1] -NoNewline
    Write-Host '|' -ForegroundColor Cyan
  }
  Write-Host $rule -ForegroundColor Cyan
}

function Fail {
  param([string]$Message)
  throw (New-Object System.InvalidOperationException ('HEIMDALL-INSTALL: ' + $Message))
}

function Test-HeimdallFailure {
  param($ErrorRecord)
  $ex = $ErrorRecord
  if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
  return ($ex -is [System.InvalidOperationException] -and $ex.Message.StartsWith('HEIMDALL-INSTALL: '))
}

function Get-ExceptionReason {
  param($Exception)
  $parts = New-Object System.Collections.Generic.List[string]
  $ex = $Exception
  while ($ex) {
    if ($ex -isnot [System.AggregateException] -and $ex.Message -and -not $parts.Contains($ex.Message.Trim())) {
      $parts.Add($ex.Message.Trim())
    }
    $ex = $ex.InnerException
  }
  if ($parts.Count -eq 0) { return 'unknown error' }
  return ($parts -join ': ')
}

function Write-Utf8File {
  param([string]$Path, [string]$Text)
  [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Each generated file in the encoding its reader assumes, so a non-ASCII profile
# path (C:\Users\Jos<e-acute>) survives: wscript reads a BOM-less .js as ANSI
# (UTF-16LE with BOM is exact), Windows PowerShell 5.1 a BOM-less .ps1 as ANSI
# (UTF-8 with BOM), and cmd.exe a batch file in the console's OEM code page.
function Get-OemEncoding {
  param()
  try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
  $cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
  try { $cp = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name OEMCP -ErrorAction Stop).OEMCP } catch { }
  return [Text.Encoding]::GetEncoding($cp, (New-Object Text.EncoderExceptionFallback), (New-Object Text.DecoderExceptionFallback))
}

function Test-OemRepresentable {
  param([string]$Text)
  try { [void](Get-OemEncoding).GetBytes($Text); return $true } catch { return $false }
}

function Write-GeneratedFile {
  param([string]$Path, [string]$Text, [ValidateSet('js', 'ps1', 'cmd')][string]$Kind)
  switch ($Kind) {
    'js' { $enc = New-Object System.Text.UnicodeEncoding($false, $true) }
    'ps1' { $enc = New-Object System.Text.UTF8Encoding($true) }
    'cmd' {
      $enc = Get-OemEncoding
      # cmd.exe decodes each batch line in the console's CURRENT code page, which
      # an interactive console may have changed (chcp 65001). Switch to the code
      # page this file is written in right after the ASCII header lines, and
      # restore the caller's one (and the exit code) at the end.
      $lines = New-Object System.Collections.Generic.List[string]
      foreach ($l in ($Text.TrimEnd("`r", "`n") -split "`r`n")) {
        if ($l -eq 'exit /b %ERRORLEVEL%') {
          $lines.Add('set "HEIMDALL_RC=%ERRORLEVEL%"')
          $lines.Add('if defined HEIMDALL_CP for /f "tokens=1 delims=. " %%c in ("%HEIMDALL_CP%") do chcp %%c >nul 2>nul')
          $lines.Add('exit /b %HEIMDALL_RC%')
          continue
        }
        $lines.Add($l)
        if ($l -eq 'setlocal DisableDelayedExpansion') {
          $lines.Add('for /f "tokens=2 delims=:" %%c in (''chcp'') do set "HEIMDALL_CP=%%c"')
          $lines.Add("chcp $($enc.CodePage) >nul 2>nul")
        }
      }
      $Text = ($lines -join "`r`n") + "`r`n"
    }
  }
  try { $bytes = $enc.GetPreamble() + $enc.GetBytes($Text) } catch { Fail "Cannot write ${Path}: a path in it is not representable in the OEM code page $($enc.CodePage) that cmd.exe reads batch files in." }
  [IO.File]::WriteAllBytes($Path, [byte[]]$bytes)
}

# Owner-only ACL (the 0700/0600 intent of install.sh): inheritance cut, every
# inherited entry dropped, one full-control entry for the current user's SID.
# Directories pass it on to everything created below them.
function Set-OwnerOnlyAcl {
  param([string]$Path)
  $ErrorActionPreference = 'Continue'
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $grant = "*${sid}:F"
  if (Test-Path -LiteralPath $Path -PathType Container) { $grant = "*${sid}:(OI)(CI)F" }
  $out = & icacls.exe $Path /inheritance:r /grant:r $grant /Q 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "Could not restrict access to ${Path}: $out" }
  for ($pass = 0; $pass -lt 2; $pass++) {
    $others = @()
    foreach ($rule in (Get-Acl -LiteralPath $Path).Access) {
      $who = "$($rule.IdentityReference)"
      try { $who = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
      if ($who -ne $sid -and $others -notcontains $who) { $others += $who }
    }
    if ($others.Count -eq 0) { return }
    if ($pass -eq 1) { Fail "Access to $Path is still granted to $($others -join ', '); remove it and re-run." }
    # Explicit entries a previous owner added survive /inheritance:r; drop them.
    foreach ($who in $others) {
      $target = $who
      if ($who -match '^S-1-') { $target = "*$who" }
      $null = & icacls.exe $Path /remove:g $target /remove:d $target /Q 2>&1
    }
  }
}

# install.sh's Python canonicalizer, rule for rule: http(s) origin only; no
# credentials, path (other than "/"), query or fragment; lower-cased host;
# compressed IPv6 in brackets; IDN to punycode; default port dropped. The service
# name keeps [a-z0-9-] and appends a non-default port. Returns $null if invalid.
function ConvertTo-HubIdentity {
  param([string]$Raw)
  # An empty "?" or "#" is accepted, as urlsplit reports both as empty.
  $m = [regex]::Match($Raw.Trim(), '^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)/?\??#?$')
  if (-not $m.Success) { return $null }
  $scheme = $m.Groups[1].Value.ToLowerInvariant()
  if ($scheme -ne 'http' -and $scheme -ne 'https') { return $null }
  $netloc = $m.Groups[2].Value
  if ($netloc.Contains('@') -or $netloc.Contains('%')) { return $null }
  $portText = ''
  if ($netloc.StartsWith('[')) {
    $close = $netloc.IndexOf(']')
    if ($close -lt 0) { return $null }
    $hostName = $netloc.Substring(1, $close - 1)
    $rest = $netloc.Substring($close + 1)
    if ($rest -ne '') {
      if (-not $rest.StartsWith(':')) { return $null }
      $portText = $rest.Substring(1)
    }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($hostName, [ref]$ip)) { return $null }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $null }
    $hostName = $ip.ToString().ToLowerInvariant()
  } else {
    if (($netloc.ToCharArray() | Where-Object { $_ -eq ':' }).Count -gt 1) { return $null }
    $hostName = $netloc
    $colon = $netloc.IndexOf(':')
    if ($colon -ge 0) { $hostName = $netloc.Substring(0, $colon); $portText = $netloc.Substring($colon + 1) }
    $hostName = $hostName.ToLowerInvariant()
    if ($hostName -eq '') { return $null }
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    if ($hostName -notmatch "^$octet(\.$octet){3}$") {
      if ($hostName -match '[^\x00-\x7F]') {
        try { $hostName = (New-Object System.Globalization.IdnMapping).GetAscii($hostName).ToLowerInvariant() } catch { return $null }
      }
      $labels = @($hostName.Split('.'))
      if ($labels.Count -gt 1 -and $labels[-1] -eq '') { $labels = $labels[0..($labels.Count - 2)] }
      foreach ($label in $labels) { if ($label.Length -lt 1 -or $label.Length -gt 63) { return $null } }
      $hostName = ($labels -join '.').TrimEnd('.')
      if ($hostName -cnotmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') { return $null }
    }
  }
  $port = 0
  if ($portText -ne '') {
    if ($portText -notmatch '^[0-9]{1,10}$') { return $null }
    $port = [long]$portText
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    if (($scheme -eq 'http' -and $port -eq 80) -or ($scheme -eq 'https' -and $port -eq 443)) { $port = 0 }
  }
  $authority = $hostName
  if ($hostName.Contains(':')) { $authority = "[$hostName]" }
  if ($port) { $authority += ":$port" }
  $name = [regex]::Replace($hostName, '[^a-z0-9-]', '-')
  if ($port) { $name += "-$port" }
  if ($name.Length -gt 160) { return $null }
  return @{ Url = "${scheme}://$authority"; Service = "heimdall-bridge-$name" }
}

function Enable-ModernTls {
  param()
  try {
    $p = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try { $p = $p -bor [Net.SecurityProtocolType]::Tls13 } catch { }
    [Net.ServicePointManager]::SecurityProtocol = $p
  } catch { }
  Add-Type -AssemblyName System.Net.Http
}

# Explicit Hub reachability check before anything is installed: one fixed
# budget, a visible timer on a terminal, and the exact reason on failure (DNS,
# TLS trust, refused, timeout). Any HTTP answer counts: a Hub behind
# forward-auth redirects unauthenticated requests, which still proves TCP+TLS.
function Wait-ForHub {
  param([string]$HubUrl)
  Write-Log INFO "Checking Hub $HubUrl (up to ${HeimdallHubTimeoutSeconds}s)"
  $handler = New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect = $false
  $client = New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds($HeimdallHubTimeoutSeconds)
  $ticker = Test-ConsoleOutput
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $task = $client.GetAsync("$HubUrl/api/v1/health")
    while (-not $task.AsyncWaitHandle.WaitOne(500)) {
      if ($ticker) { [Console]::Error.Write(("`r  waiting for Hub... {0,2}s / {1}s " -f [int]$sw.Elapsed.TotalSeconds, $HeimdallHubTimeoutSeconds)) }
    }
    if ($ticker) { [Console]::Error.Write("`r" + (' ' * 40) + "`r") }
    $secs = [int]$sw.Elapsed.TotalSeconds
    if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
      Write-Log OK "Hub reachable: HTTP $([int]$task.Result.StatusCode) after ${secs}s"
      $task.Result.Dispose()
      return
    }
    if ($task.IsCanceled) { $reason = "timed out after ${HeimdallHubTimeoutSeconds}s" } else { $reason = Get-ExceptionReason $task.Exception }
    Fail "Hub $HubUrl not reachable (gave up after ${secs}s of ${HeimdallHubTimeoutSeconds}s): $reason"
  } finally {
    $client.Dispose()
  }
}

function Save-Url {
  param([string]$Url, [string]$Path, [switch]$ShowProgress)
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(600)
  [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd('heimdall-install.ps1')
  $progress = $ShowProgress -and (Test-ConsoleOutput)
  try {
    try {
      $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    } catch {
      Fail "Download failed: $Url ($(Get-ExceptionReason $_.Exception))"
    }
    if (-not $resp.IsSuccessStatusCode) { Fail "Download failed: $Url (HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase))" }
    $total = $resp.Content.Headers.ContentLength
    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $out = [IO.File]::Create($Path)
    try {
      $buf = New-Object byte[] 262144
      $done = 0L
      $last = [DateTime]::MinValue
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n)
        $done += $n
        if ($progress -and ([DateTime]::UtcNow - $last).TotalMilliseconds -ge 250) {
          $last = [DateTime]::UtcNow
          if ($total) { $msg = "`r  downloading {0,3}% of {1:N1} MB " -f [int](100 * $done / $total), ($total / 1MB) } else { $msg = "`r  downloading {0:N1} MB " -f ($done / 1MB) }
          [Console]::Error.Write($msg)
        }
      }
    } catch {
      if (Test-HeimdallFailure $_) { throw }
      Fail "Download failed: $Url ($(Get-ExceptionReason $_.Exception))"
    } finally {
      $out.Dispose()
      $in.Dispose()
      if ($progress) { [Console]::Error.Write("`r" + (' ' * 48) + "`r") }
    }
  } finally {
    $client.Dispose()
  }
}

function Get-ExpectedSha256 {
  param([string]$SumsFile, [string]$Name)
  $found = @()
  foreach ($line in [IO.File]::ReadAllLines($SumsFile)) {
    $f = @($line.Trim() -split '\s+')
    if ($f.Count -eq 2 -and $f[1].TrimStart('*') -ceq $Name) { $found += $f[0].ToLowerInvariant() }
  }
  if ($found.Count -ne 1) { return $null }
  return $found[0]
}

function Test-Sha256 {
  param([string]$SumsFile, [string]$File, [string]$Name)
  $expected = Get-ExpectedSha256 $SumsFile $Name
  if (-not $expected) { return $false }
  return ((Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLowerInvariant() -eq $expected)
}

# Extract only the expected regular files, each to a fixed name in $Dest; no
# archive entry name is ever used as a path. Absolute, drive-qualified or ".."
# entries anywhere in the archive, duplicates, directories or links where a file
# is expected, and oversized entries reject the whole bundle.
function Expand-HeimdallBundle {
  param([string]$Zip, [string]$Dest)
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $wanted = @(
    @('bin/ham-bridge.exe', 'ham-bridge.exe', $true),
    @('bin/ham-pty-host.exe', 'ham-pty-host.exe', $true),
    @('bin/ham-ctl.exe', 'ham-ctl.exe', $true),
    @('bin/heimdall.exe', 'heimdall.exe', $false),
    @('scripts/apply-bridge-update.ps1', 'apply-bridge-update.ps1', $false)
  )
  try { $z = [IO.Compression.ZipFile]::OpenRead($Zip) } catch { Fail "The release bundle is not a readable zip: $(Get-ExceptionReason $_.Exception)" }
  try {
    $names = @{}
    foreach ($e in $z.Entries) {
      $n = $e.FullName.Replace('\', '/')
      while ($n.StartsWith('./')) { $n = $n.Substring(2) }
      if ($n.StartsWith('/') -or $n -match '^[A-Za-z]:' -or (@($n.Split('/')) -contains '..')) { Fail "Unsafe path in release bundle: $($e.FullName)" }
      $names[$e.FullName] = $n
    }
    foreach ($w in $wanted) {
      $hits = @($z.Entries | Where-Object { $names[$_.FullName] -ieq $w[0] })
      if ($hits.Count -eq 0) {
        if ($w[2]) { Fail "Missing/unsafe binary: $($w[0])" }
        continue
      }
      $e = $hits[0]
      $unixType = 0
      try { $unixType = ([long]$e.ExternalAttributes -shr 16) -band 0xF000 } catch { }
      if ($hits.Count -ne 1 -or $e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\') -or ($unixType -ne 0 -and $unixType -ne 0x8000) -or $e.Length -gt 512MB) {
        Fail "Missing/unsafe binary: $($w[0])"
      }
      $in = $e.Open()
      $out = [IO.File]::Create((Join-Path $Dest $w[1]))
      try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
    }
  } finally {
    $z.Dispose()
  }
}

function Get-BridgeVersion {
  param([string]$Exe)
  $ErrorActionPreference = 'Continue'
  try { $line = (& $Exe --version 2>$null | Select-Object -First 1) } catch { return '' }
  $f = @("$line".Trim() -split '\s+')
  if ($f.Count -ge 2 -and $f[0] -eq 'ham-bridge') { return $f[1] }
  return ''
}

function Test-VersionAtLeast {
  param([string]$Have, [string]$Want)
  $h = $Have.TrimStart('v').Split('-')[0]
  try { return ([version]$h -ge [version]$Want) } catch { return $false }
}

# Free loopback port pair per Hub, as install.sh: reuse this Hub's ports.json when
# they are still free, never take another Hub's, skip anything already listening.
function Select-BridgePorts {
  param([string]$StateRoot, [string]$StateDir)
  $reserved = @{}
  $preferred = @(49323, 49324)
  foreach ($d in @(Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue)) {
    $f = Join-Path $d.FullName 'ports.json'
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try {
      # Windows PowerShell 5.1 emits a JSON array as ONE pipeline object: enumerate it with foreach.
      $raw = [IO.File]::ReadAllText($f) | ConvertFrom-Json
      $p = @(foreach ($x in $raw) { [int]$x })
      if ($d.FullName -eq $StateDir) { if ($p.Count -eq 2) { $preferred = $p } } else { foreach ($x in $p) { $reserved[$x] = $true } }
    } catch { }
  }
  $listening = @{}
  foreach ($ep in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) { $listening[$ep.Port] = $true }
  $held = @()
  $result = @()
  try {
    foreach ($start in $preferred) {
      $found = $false
      for ($port = [Math]::Max(1024, [int]$start); $port -le 65535; $port++) {
        if ($reserved.ContainsKey($port) -or $listening.ContainsKey($port) -or ($result -contains $port)) { continue }
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
        $l.ExclusiveAddressUse = $true
        try { $l.Start() } catch { continue }
        $held += $l
        $result += $port
        $found = $true
        break
      }
      if (-not $found) { Fail 'No free bridge ports available.' }
    }
  } finally {
    foreach ($l in $held) { $l.Stop() }
  }
  Write-Utf8File (Join-Path $StateDir 'ports.json') ('[' + ($result -join ', ') + "]`n")
  return $result
}

function ConvertTo-PsLiteral {
  param([string]$Value)
  # Also escapes the typographic quotes PowerShell treats as single quotes.
  return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

function ConvertTo-CmdValue {
  param([string]$Value)
  return $Value.Replace('%', '%%')
}

function Install-BinaryFile {
  param([string]$Source, [string]$Dest)
  # A running image cannot be overwritten but can be renamed: move the old one
  # aside so a stray ham-ctl.exe still running never blocks the replacement.
  if (Test-Path -LiteralPath $Dest) {
    $old = "$Dest.old-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Move-Item -LiteralPath $Dest -Destination $old
    try { Copy-Item -LiteralPath $Source -Destination $Dest } catch { Move-Item -LiteralPath $old -Destination $Dest; throw }
    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
  } else {
    Copy-Item -LiteralPath $Source -Destination $Dest
  }
}

# ---- service helpers (also embedded into the generated enroll.ps1) ----

function Get-LogTail {
  param([string]$Path, [int]$Lines = 15)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try { return ((Get-Content -LiteralPath $Path -Tail $Lines) -join "`n") } catch { return '' }
}

function Get-BridgeProcesses {
  param($C)
  $prefix = $C.BinDir.TrimEnd('\') + '\'
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) -or
      ($_.Name -eq 'wscript.exe' -and $_.CommandLine -and $_.CommandLine.IndexOf($C.Launcher, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
}

# Stop this Hub's task: the hidden wscript service loop first (so nothing
# restarts the bridge), then the update supervisor's PTY-host cleanup when the
# bundle shipped one, then anything still running from this Hub's bin dir.
function Stop-BridgeService {
  param($C)
  $task = Get-ScheduledTask -TaskPath '\' -TaskName $C.ServiceName -ErrorAction SilentlyContinue
  if ($task) { Stop-ScheduledTask -TaskPath '\' -TaskName $C.ServiceName -ErrorAction SilentlyContinue }
  foreach ($p in @(Get-BridgeProcesses $C | Where-Object { $_.Name -eq 'wscript.exe' })) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  $supervisor = Join-Path $C.UpdatesDir 'apply-bridge-update.ps1'
  if ((Test-Path -LiteralPath $supervisor) -and @(Get-BridgeProcesses $C).Count -gt 0) {
    try {
      $sp = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$supervisor`"", '--data-dir', "`"$($C.DataDir)`"", '--stop-pty-hosts-only')
      if (-not $sp.WaitForExit(15000)) { Stop-Process -Id $sp.Id -Force -ErrorAction SilentlyContinue }
    } catch { }
  }
  $left = @(Get-BridgeProcesses $C)
  foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($p in $left) { Wait-Process -Id $p.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }
  if (@(Get-BridgeProcesses $C).Count -gt 0) { Fail "Could not stop the running bridge processes under $($C.BinDir)." }
}

function Start-BridgeService {
  param($C)
  Start-ScheduledTask -TaskPath '\' -TaskName $C.ServiceName
}

# Ready = the task is running and this Hub's ham-bridge.exe is listening on its
# loopback port.
function Wait-BridgeReady {
  param($C, [int]$Seconds = 20)
  $exe = Join-Path $C.BinDir 'ham-bridge.exe'
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ([DateTime]::UtcNow -lt $deadline) {
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $C.ServiceName -ErrorAction SilentlyContinue
    $listening = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $C.BridgePort }).Count -gt 0
    $running = @(Get-BridgeProcesses $C | Where-Object { $_.ExecutablePath -ieq $exe }).Count -gt 0
    if ($task -and "$($task.State)" -eq 'Running' -and $listening -and $running) { Clear-Tick; return $true }
    Write-Tick 'waiting for the service' $sw
    Start-Sleep -Milliseconds 500
  }
  Clear-Tick
  return $false
}

# ham-bridge enroll prints the pairing code (typed at <hub>/device/add on an
# approved browser) and, on Windows, exits 0 without restarting any service. It
# gets the same tool paths the task's environment carries, so the enrolling
# process can start the PTY host and ham-ctl too. ham-bridge enroll refuses while
# a bridge runs on the same config, so this Hub's task is stopped first.
function Invoke-BridgeEnroll {
  param($C)
  Stop-BridgeService $C
  $vars = [ordered]@{
    'PATH'                      = $C.BinDir + ';' + $env:PATH
    'HEIMDALL_HAM_PTY_HOST_BIN' = (Join-Path $C.BinDir 'ham-pty-host.exe')
    'HEIMDALL_BRIDGE_PTY_HOST'  = 'true'
    'HEIMDALL_HAM_CTL_BIN'      = (Join-Path $C.BinDir 'ham-ctl.exe')
  }
  $saved = @{}
  foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
  $status = 1
  try {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
    & (Join-Path $C.BinDir 'ham-bridge.exe') enroll --hub $C.HubUrl --bridge-token-file $C.TokenFile --config $C.ConfigFile `
      --data-dir $C.DataDir --port "$($C.BridgePort)" --local-endpoint-port "$($C.EndpointPort)" --local-run-dir $C.RunDir
    $status = $LASTEXITCODE
  } finally {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
  $hasToken = (Test-Path -LiteralPath $C.TokenFile) -and ((Get-Item -LiteralPath $C.TokenFile).Length -gt 0)
  if ($status -eq 3 -and $hasToken) {
    Write-Log WARN 'Enrollment succeeded; the bridge could not restart a service itself. Continuing with task start and readiness checks.'
  } elseif ($status -ne 0) {
    Fail "Enrollment failed (status $status). The task $($C.ServiceName) is registered but not running. Re-run the installer with -ReEnroll, or enroll later with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$($C.EnrollScript)`""
  }
  if (-not $hasToken) { Fail 'Enrollment did not write a credential.' }
  Set-OwnerOnlyAcl $C.TokenFile
}

$HeimdallEmbeddedFunctions = @('Test-HeimdallColour', 'Test-ConsoleOutput', 'Format-Elapsed', 'Write-Tick', 'Clear-Tick', 'Write-Log', 'Fail', 'Test-HeimdallFailure', 'Set-OwnerOnlyAcl', 'Get-LogTail', 'Get-BridgeProcesses',
  'Stop-BridgeService', 'Start-BridgeService', 'Wait-BridgeReady', 'Invoke-BridgeEnroll')

# Persist a usable enrollment command even when the installer came from irm:
# stop this Hub's task, enroll, start the task and check it is ready.
function New-EnrollScript {
  param($C)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# Enroll (or re-enroll) the Heimdall bridge for $($C.HubUrl), then start its task.")
  [void]$sb.AppendLine("# Generated by install.ps1. Run: powershell -NoProfile -ExecutionPolicy Bypass -File `"$($C.EnrollScript)`"")
  [void]$sb.AppendLine('$ErrorActionPreference = ''Stop''')
  foreach ($n in $HeimdallEmbeddedFunctions) {
    [void]$sb.AppendLine("function $n {")
    [void]$sb.AppendLine((Get-Item "function:$n").ScriptBlock.ToString())
    [void]$sb.AppendLine('}')
  }
  [void]$sb.AppendLine('$C = @{')
  foreach ($k in ($C.Keys | Sort-Object)) {
    $v = $C[$k]
    if ($v -is [int]) { [void]$sb.AppendLine("  $k = $v") } else { [void]$sb.AppendLine("  $k = $(ConvertTo-PsLiteral "$v")") }
  }
  [void]$sb.AppendLine('}')
  [void]$sb.AppendLine(@'
try {
  Invoke-BridgeEnroll $C
  Write-Log OK 'Browser-approved enrollment complete'
  Start-BridgeService $C
  if (-not (Wait-BridgeReady $C)) { Fail "Task $($C.ServiceName) did not start. Logs: $($C.LogDir)`n$(Get-LogTail (Join-Path $C.LogDir 'bridge.err.log'))" }
  Write-Log OK "Service running: $($C.ServiceName)"
} catch {
  if (Test-HeimdallFailure $_) { $m = $_.Exception.Message.Substring(18) } else { $m = "$_" }
  Write-Host ''
  Write-Host "[ERROR] $m"
  exit 1
}
'@)
  Write-GeneratedFile $C.EnrollScript $sb.ToString() ps1
}

function New-TaskXml {
  param($C)
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $e = { param($s) [Security.SecurityElement]::Escape("$s") }
  $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $taskArgs = '//B //NoLogo "' + $C.Launcher + '"'
  return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(& $e "Heimdall Bridge for $($C.HubUrl) (installed by install.ps1)")</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$(& $e $id.Name)</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $e $id.User.Value)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $e $wscript)</Command>
      <Arguments>$(& $e $taskArgs)</Arguments>
      <WorkingDirectory>$(& $e $C.DataDir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Invoke-HeimdallInstaller {
  param([hashtable]$O)
  $hubUrl = $O.Hub
  $version = $O.Version
  $noninteractive = [bool]$O.NonInteractive
  $enrollment = 'ask'
  if ($O.ReEnroll -and $O.KeepEnrollment) { Fail '-ReEnroll and -KeepEnrollment are mutually exclusive.' }
  if ($O.ReEnroll) { $enrollment = 'yes' }
  if ($O.KeepEnrollment) { $enrollment = 'no' }
  if ($env:HEIMDALL_NON_INTERACTIVE -eq '1') { $noninteractive = $true }
  if (-not $hubUrl -and -not $HeimdallPinnedHub.StartsWith('@@')) { $hubUrl = $HeimdallPinnedHub }
  if (-not $version -and -not $HeimdallPinnedVersion.StartsWith('@@')) { $version = $HeimdallPinnedVersion }

  Write-Banner $version $hubUrl
  Write-Step 1 'Hub & platform'
  if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { Fail 'This installer is for Windows. On Linux and macOS use scripts/install.sh.' }
  if (-not $hubUrl) {
    if ($noninteractive) { Fail '-Hub is required in non-interactive mode.' }
    try { $hubUrl = Read-Host -Prompt 'Hub URL' } catch { Fail 'No terminal available. Pass -Hub URL.' }
  }
  $identity = ConvertTo-HubIdentity "$hubUrl"
  if (-not $identity) { Fail 'Invalid Hub URL: use an HTTP(S) origin with no path, credentials, query, or fragment.' }
  $hubUrl = $identity.Url
  $serviceName = $identity.Service

  $arch = ''
  try { $arch = "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" } catch { }
  if (-not $arch) { $arch = $env:PROCESSOR_ARCHITEW6432; if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE } }
  switch -regex ($arch) {
    '^(X64|AMD64)$' { break }
    '^(Arm64|ARM64)$' { Write-Log INFO 'Windows on Arm: installing the x64 bundle (runs under x64 emulation).'; break }
    default { Fail "Supported architecture: x64 (amd64); this machine reports '$arch'." }
  }
  $me = [Security.Principal.WindowsIdentity]::GetCurrent()
  if ((New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log WARN "Running elevated. The task is still installed for $($me.Name) without elevation; if that is not your login account, re-run from a normal PowerShell."
  }
  if (-not $env:APPDATA -or -not $env:LOCALAPPDATA) { Fail 'APPDATA and LOCALAPPDATA must be set (run in your normal Windows login session).' }

  $stateRoot = Join-Path $env:APPDATA 'heimdall\bridges'
  $stateDir = Join-Path $stateRoot $serviceName
  $dataDir = Join-Path $env:LOCALAPPDATA "heimdall\bridges\$serviceName"
  $binDir = Join-Path $dataDir 'bin'
  $C = @{
    HubUrl       = $hubUrl
    ServiceName  = $serviceName
    StateDir     = $stateDir
    DataDir      = $dataDir
    BinDir       = $binDir
    RunDir       = (Join-Path $dataDir 'run')
    LogDir       = (Join-Path $dataDir 'logs')
    UpdatesDir   = (Join-Path $dataDir 'updates')
    TokenFile    = (Join-Path $stateDir 'bridge-token')
    ConfigFile   = (Join-Path $stateDir 'config.toml')
    EnrollScript = (Join-Path $stateDir 'enroll.ps1')
    Launcher     = (Join-Path $binDir 'bridge-service.js')
    RunCmd       = (Join-Path $binDir 'bridge-run.cmd')
    CtlWrapper   = (Join-Path $binDir "ham-ctl-$serviceName.cmd")
    BridgePort   = 0
    EndpointPort = 0
  }
  Write-Log INFO "Hub: $hubUrl"
  Write-Log INFO "Service: $serviceName ($HeimdallTarget, Scheduled Task)"
  Write-Log INFO "Config/token: $stateDir"
  Write-Log INFO "Data/binaries: $dataDir"
  # Fail before anything is touched if a path cannot go into the generated files:
  # cmd.exe and WScript.Shell.Run expand %VAR% (there is no escape on a command
  # line), and batch files are read in the OEM code page.
  foreach ($d in @($stateDir, $dataDir)) {
    if ($d.Contains('%')) { Fail "The profile path $d contains '%', which cmd.exe would expand; set APPDATA/LOCALAPPDATA to a path without it." }
    if (-not (Test-OemRepresentable $d)) { Fail "The profile path $d is not representable in this system's OEM code page, which cmd.exe reads the bridge's batch files in; set APPDATA/LOCALAPPDATA to a path that is (or enable 'Beta: Use Unicode UTF-8' in Region settings)." }
  }
  $hubFile = Join-Path $stateDir 'hub-url'
  if (Test-Path -LiteralPath $hubFile) {
    $owner = ([IO.File]::ReadAllText($hubFile)).Trim()
    if ($owner -ne $hubUrl) { Fail "Name collision with $owner. Use a distinct hostname/port." }
  }

  if ($O.Uninstall) {
    if ($O.DryRun) { Write-Log PLAN "Remove scheduled task $serviceName and $binDir; preserve $stateDir and $dataDir"; return }
    Stop-BridgeService $C
    if (Get-ScheduledTask -TaskPath '\' -TaskName $serviceName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskPath '\' -TaskName $serviceName -Confirm:$false
      Write-Log OK "Removed task $serviceName"
    }
    if (Test-Path -LiteralPath $binDir) {
      try { Remove-Item -LiteralPath $binDir -Recurse -Force } catch { Fail "Could not remove ${binDir}: $(Get-ExceptionReason $_.Exception)" }
    }
    Write-Log OK 'Uninstalled. Enrollment and agent data preserved.'
    return
  }

  $existing = (Test-Path -LiteralPath $C.TokenFile) -and ((Get-Item -LiteralPath $C.TokenFile).Length -gt 0)
  if ($existing -and $enrollment -eq 'ask') {
    if ($noninteractive -or $O.DryRun) { $enrollment = 'no' }
    else {
      $answer = $null
      try { $answer = Read-Host -Prompt 'Existing enrollment found. Re-enroll this bridge? [y/N]' } catch { }
      if ("$answer" -match '^(y|yes)$') { $enrollment = 'yes' } else { $enrollment = 'no' }
    }
  } elseif (-not $existing) {
    $enrollment = 'yes'
  }

  if ($O.DryRun) {
    Write-Step '' 'Dry-run plan'
    Write-Log PLAN "Replace scheduled task $serviceName (at logon, no window, restart on failure); enrollment=$enrollment"
    Write-Log PLAN 'Choose two free loopback ports; create a per-Hub ham-ctl wrapper and task.'
    if ($O.FromDir) { Write-Log PLAN "Install ham-bridge.exe, ham-pty-host.exe, ham-ctl.exe from $($O.FromDir) (no download or checksum)." }
    else {
      $shown = 'LATEST'
      if ($version) { $shown = $version }
      Write-Log PLAN "Download heimdall-local-$HeimdallTarget-$shown.zip and verify SHA256SUMS."
    }
    return
  }
  foreach ($tool in @('icacls.exe', 'wscript.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool is required (Windows component missing)." }
  }
  if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { Fail 'The ScheduledTasks PowerShell module is required (Windows 8 / Server 2012 or newer).' }

  New-Item -ItemType Directory -Force $stateRoot | Out-Null
  $lockDir = Join-Path $stateRoot '.install-lock'
  $lockHeld = $false
  $workDir = $null
  try {
    try { New-Item -ItemType Directory $lockDir -ErrorAction Stop | Out-Null; $lockHeld = $true } catch { }
    if (-not $lockHeld) {
      # A lock whose owner is gone (window closed mid-install) is stale.
      $ownerPid = 0
      try { $ownerPid = [int]([IO.File]::ReadAllText((Join-Path $lockDir 'pid')).Trim()) } catch { }
      $alive = $ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(powershell|pwsh)$' })
      if ($alive -or -not (Test-Path -LiteralPath (Join-Path $lockDir 'pid'))) { Fail "Another installer is running (lock: $lockDir)." }
      Write-Log WARN "Removing stale installer lock from process $ownerPid"
      Remove-Item -LiteralPath $lockDir -Recurse -Force
      try { New-Item -ItemType Directory $lockDir -ErrorAction Stop | Out-Null; $lockHeld = $true } catch { Fail "Another installer is running (lock: $lockDir)." }
    }
    Write-Utf8File (Join-Path $lockDir 'pid') "$PID"
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $workDir | Out-Null
    Set-OwnerOnlyAcl $workDir

    Enable-ModernTls
    Write-Step 2 'Hub check'
    Wait-ForHub $hubUrl

    Write-Step 3 'Resolve release'
    if ($O.FromDir) {
      Write-Log INFO 'Local binaries (-FromDir): no release lookup.'
      Write-Step 4 'Download & verify'
      if (-not (Test-Path -LiteralPath $O.FromDir -PathType Container)) { Fail "-FromDir $($O.FromDir) is not a directory." }
      $src = (Resolve-Path -LiteralPath $O.FromDir).Path
      if (Test-Path -LiteralPath (Join-Path $src 'bin\ham-bridge.exe')) { $src = Join-Path $src 'bin' }
      foreach ($f in @('ham-bridge.exe', 'ham-pty-host.exe', 'ham-ctl.exe')) {
        $p = Join-Path $src $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "-FromDir is missing $f (looked in $src)." }
        Copy-Item -LiteralPath $p -Destination (Join-Path $workDir $f)
      }
      if (Test-Path -LiteralPath (Join-Path $src 'heimdall.exe') -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $src 'heimdall.exe') -Destination $workDir }
      foreach ($cand in @((Join-Path $src 'apply-bridge-update.ps1'), (Join-Path (Split-Path -Parent $src) 'scripts\apply-bridge-update.ps1'))) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) { Copy-Item -LiteralPath $cand -Destination (Join-Path $workDir 'apply-bridge-update.ps1'); break }
      }
      Write-Log WARN "Installing local binaries from $src (not a verified release)"
    } else {
      $api = $HeimdallRepoApi
      $dlRoot = $HeimdallRepoDownload
      if ($env:HEIMDALL_INSTALL_TEST_RELEASES) {
        # Loopback only: the seam must never point a real install at a remote mirror.
        if ($env:HEIMDALL_INSTALL_TEST_RELEASES -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/|$)') { Fail 'HEIMDALL_INSTALL_TEST_RELEASES must be a loopback http:// URL (test seam only).' }
        # Test seam for the hermetic installer test: a local release mirror.
        $api = $env:HEIMDALL_INSTALL_TEST_RELEASES.TrimEnd('/') + '/releases.json'
        $dlRoot = $env:HEIMDALL_INSTALL_TEST_RELEASES.TrimEnd('/') + '/download'
        Write-Log WARN "Using test release source $($env:HEIMDALL_INSTALL_TEST_RELEASES)"
      }
      if (-not $version) {
        # Releases start as prereleases (candidates on the canary hub) and are
        # promoted later; without -Version, resolve only promoted releases. A hub's
        # own /public/install.ps1 pins the hub's release.
        $relFile = Join-Path $workDir 'releases.json'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Write-Log INFO 'Looking up the latest promoted release'
        Save-Url $api $relFile
        try { $raw = [IO.File]::ReadAllText($relFile) | ConvertFrom-Json } catch { Fail 'GitHub did not return a release list; pass -Version TAG.' }
        # PowerShell 7 unwraps a one-element array; an object without tag_name is an API error.
        if ($raw -and $raw -isnot [array] -and -not $raw.tag_name) { Fail 'GitHub did not return a release list; pass -Version TAG.' }
        foreach ($r in $raw) {
          $tag = "$($r.tag_name)"
          $assets = @($r.assets | ForEach-Object { "$($_.name)" })
          if (-not $r.draft -and -not $r.prerelease -and ($assets -ccontains 'SHA256SUMS') -and ($assets -ccontains "heimdall-local-$HeimdallTarget-$tag.zip")) { $version = $tag; break }
        }
        if (-not $version) { Fail 'No promoted release bundle for this platform. Pass -Version TAG.' }
        Write-Log OK "Latest release: $version ($(Format-Elapsed $sw.Elapsed.TotalSeconds))"
      }
      if ($version -notmatch '^[a-zA-Z0-9._-]+$') { Fail 'Invalid release tag.' }
      $archive = "heimdall-local-$HeimdallTarget-$version.zip"
      $base = "$dlRoot/$version"
      Write-Step 4 'Download & verify'
      Write-Log INFO "Downloading $version"
      $sums = Join-Path $workDir 'SHA256SUMS'
      Save-Url "$base/SHA256SUMS" $sums
      if (-not (Get-ExpectedSha256 $sums $archive)) { Fail "Release $version has no $archive in its SHA256SUMS." }
      $cacheDir = Join-Path $env:LOCALAPPDATA 'heimdall\cache\releases'
      New-Item -ItemType Directory -Force $cacheDir | Out-Null
      Set-OwnerOnlyAcl $cacheDir
      $cached = Join-Path $cacheDir $archive
      $bundle = Join-Path $workDir $archive
      if ((Test-Path -LiteralPath $cached) -and (Test-Sha256 $sums $cached $archive)) {
        Copy-Item -LiteralPath $cached -Destination $bundle
        Write-Log OK "Using cached $archive (SHA-256 matches release $version; no download)"
      } else {
        Save-Url "$base/$archive" $bundle -ShowProgress
      }
      if (-not (Test-Sha256 $sums $bundle $archive)) { Fail 'SHA-256 verification failed; nothing installed.' }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      if (Test-ConsoleOutput) { Write-Progress -Activity 'Unpacking the release bundle' -Status $archive }
      try { Expand-HeimdallBundle $bundle $workDir } finally { if (Test-ConsoleOutput) { Write-Progress -Activity 'Unpacking the release bundle' -Completed } }
      Write-Log OK "Release checksum and bundle verified ($(Format-Elapsed $sw.Elapsed.TotalSeconds))"
    }

    # Preflight through the BRIDGE's own transport (SChannel TLS) before the task
    # is replaced: HttpClient reaching the Hub says nothing about this binary.
    Write-Step 5 'Bridge preflight'
    $workBridge = Join-Path $workDir 'ham-bridge.exe'
    $bridgeVersion = Get-BridgeVersion $workBridge
    if ($bridgeVersion -and (Test-VersionAtLeast $bridgeVersion '0.3.36')) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      if (Test-ConsoleOutput) { Write-Progress -Activity 'Probing the Hub through the new ham-bridge' -Status $hubUrl }
      try { & $workBridge --probe-hub $hubUrl } finally { if (Test-ConsoleOutput) { Write-Progress -Activity 'Probing the Hub through the new ham-bridge' -Completed } }
      if ($LASTEXITCODE -ne 0) { Fail "The new ham-bridge.exe cannot reach $hubUrl through its own HTTPS client (its static libcurl, Schannel and the Windows certificate store) although the installer could. Check TLS trust (HAM_TLS_CA_FILE). ham-bridge never uses a proxy. Nothing was replaced." }
      Write-Log OK "Bridge reached the Hub through its own HTTPS client ($(Format-Elapsed $sw.Elapsed.TotalSeconds))"
    } else {
      $shownVersion = 'unknown'
      if ($bridgeVersion) { $shownVersion = $bridgeVersion }
      Write-Log INFO "Bridge $shownVersion predates --probe-hub (0.3.36); transport preflight skipped."
    }
    if (-not $O.FromDir) {
      # Keep the verified bundle for next time; drop older versions of this target.
      Copy-Item -LiteralPath $bundle -Destination "$cached.tmp" -Force
      Move-Item -LiteralPath "$cached.tmp" -Destination $cached -Force
      Get-ChildItem -LiteralPath $cacheDir -Filter "heimdall-local-$HeimdallTarget-*.zip" | Where-Object { $_.Name -ne $archive } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Step 6 'Replace service'
    Stop-BridgeService $C
    if (Get-ScheduledTask -TaskPath '\' -TaskName $serviceName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskPath '\' -TaskName $serviceName -Confirm:$false
      Write-Log OK "Removed task $serviceName"
    }
    foreach ($d in @($stateDir, $dataDir, $binDir, $C.RunDir, $C.LogDir)) {
      New-Item -ItemType Directory -Force $d | Out-Null
      Set-OwnerOnlyAcl $d
    }
    Get-ChildItem -LiteralPath $binDir -Filter '*.old-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($f in @('ham-bridge.exe', 'ham-pty-host.exe', 'ham-ctl.exe', 'heimdall.exe')) {
      $p = Join-Path $workDir $f
      if (Test-Path -LiteralPath $p) { Install-BinaryFile $p (Join-Path $binDir $f) }
    }
    if (Test-Path -LiteralPath (Join-Path $workDir 'apply-bridge-update.ps1')) {
      New-Item -ItemType Directory -Force $C.UpdatesDir | Out-Null
      Copy-Item -LiteralPath (Join-Path $workDir 'apply-bridge-update.ps1') -Destination (Join-Path $C.UpdatesDir 'apply-bridge-update.ps1') -Force
    }
    Write-Utf8File $hubFile "$hubUrl`n"
    Write-Log OK "Installed binaries to $binDir"

    Write-Step 7 'Ports & routing'
    $ports = Select-BridgePorts $stateRoot $stateDir
    $C.BridgePort = [int]$ports[0]
    $C.EndpointPort = [int]$ports[1]
    Write-Log OK "Bridge: 127.0.0.1:$($C.BridgePort) - Agent endpoint: 127.0.0.1:$($C.EndpointPort)"
    if (-not (Test-Path -LiteralPath $C.ConfigFile)) {
      # The config parser takes quoted strings verbatim (no escapes): forward slashes.
      $dataFwd = $dataDir.Replace('\', '/')
      Write-Utf8File $C.ConfigFile "[daemon]`ndaemon_url = `"$hubUrl`"`ndata_dir = `"$dataFwd`"`n`n[wrapper]`ndaemon_url = `"$hubUrl`"`n"
    }
    $endpoint = "tcp:127.0.0.1:$($C.EndpointPort)"
    # Do not override the endpoint injected into agent run directories.
    Write-GeneratedFile -Kind cmd -Path $C.CtlWrapper -Text ((@(
          '@echo off',
          "rem Heimdall ham-ctl for $hubUrl (generated by install.ps1)",
          'setlocal DisableDelayedExpansion',
          "if not defined HEIMDALL_BRIDGE_ENDPOINT set `"HEIMDALL_BRIDGE_ENDPOINT=$endpoint`"",
          "`"$(ConvertTo-CmdValue (Join-Path $binDir 'ham-ctl.exe'))`" --config `"$(ConvertTo-CmdValue $C.ConfigFile)`" %*",
          'exit /b %ERRORLEVEL%') -join "`r`n") + "`r`n")
    $bridgeArgs = @('--hub', $hubUrl, '--config', $C.ConfigFile, '--bridge-token-file', $C.TokenFile, '--data-dir', $dataDir,
      '--bind-host', '127.0.0.1', '--port', "$($C.BridgePort)", '--local-endpoint-port', "$($C.EndpointPort)", '--local-run-dir', $C.RunDir)
    $quoted = ($bridgeArgs | ForEach-Object { if ($_ -match '^[A-Za-z0-9_.:/=-]+$') { $_ } else { '"' + (ConvertTo-CmdValue $_) + '"' } }) -join ' '
    $env1 = [ordered]@{
      'HEIMDALL_HAM_PTY_HOST_BIN'    = (Join-Path $binDir 'ham-pty-host.exe')
      'HEIMDALL_BRIDGE_PTY_HOST'     = 'true'
      'HEIMDALL_HAM_CTL_BIN'         = $C.CtlWrapper
      'HEIMDALL_BRIDGE_ENDPOINT'     = $endpoint
      'HEIMDALL_BRIDGE_SERVICE_NAME' = $serviceName
    }
    $runLines = @('@echo off', "rem Heimdall bridge for $hubUrl (generated by install.ps1; run by bridge-service.js)", 'setlocal DisableDelayedExpansion',
      "set `"PATH=$(ConvertTo-CmdValue $binDir);%PATH%`"")
    foreach ($k in $env1.Keys) { $runLines += "set `"$k=$(ConvertTo-CmdValue $env1[$k])`"" }
    $runLines += "`"$(ConvertTo-CmdValue (Join-Path $binDir 'ham-bridge.exe'))`" $quoted 1>>`"$(ConvertTo-CmdValue (Join-Path $C.LogDir 'bridge.out.log'))`" 2>>`"$(ConvertTo-CmdValue (Join-Path $C.LogDir 'bridge.err.log'))`""
    $runLines += 'exit /b %ERRORLEVEL%'
    Write-GeneratedFile $C.RunCmd (($runLines -join "`r`n") + "`r`n") cmd
    # wscript.exe has no console, and Run(..., 0) starts cmd hidden: the task never
    # shows a window (powershell -WindowStyle Hidden flashes one, or opens a
    # Windows Terminal tab). The loop is the restart policy: like systemd
    # Restart=on-failure, a clean exit 0 (update hand-off) ends it.
    $js = @"
// Heimdall bridge service loop for $serviceName (generated by install.ps1).
var sh = new ActiveXObject("WScript.Shell");
var fso = new ActiveXObject("Scripting.FileSystemObject");
var runCmd = $(ConvertTo-Json $C.RunCmd);
var logs = [$(ConvertTo-Json (Join-Path $C.LogDir 'bridge.out.log')), $(ConvertTo-Json (Join-Path $C.LogDir 'bridge.err.log'))];
var comspec = sh.ExpandEnvironmentStrings("%ComSpec%");
function rotate(p) {
  try {
    if (fso.FileExists(p) && fso.GetFile(p).Size > 10485760) {
      if (fso.FileExists(p + ".1")) fso.DeleteFile(p + ".1", true);
      fso.MoveFile(p, p + ".1");
    }
  } catch (e) {}
}
for (;;) {
  for (var i = 0; i < logs.length; i++) rotate(logs[i]);
  var rc = sh.Run('"' + comspec + '" /d /v:off /s /c ""' + runCmd + '""', 0, true);
  if (rc === 0) break;
  WScript.Sleep(5000);
}
"@
    Write-GeneratedFile $C.Launcher $js js
    New-EnrollScript $C
    Write-Log OK "Hub-specific CLI: $($C.CtlWrapper)"

    Write-Step 8 'Register & enroll'
    # Registered but NOT started: a token-less bridge would only exit and restart,
    # and an enrolled task must not connect while enrollment delivers the vault key.
    Register-ScheduledTask -TaskPath '\' -TaskName $serviceName -Xml (New-TaskXml $C) -Force | Out-Null
    Write-Log OK "Registered Scheduled Task $serviceName (at logon, no window, restarts on failure)"
    if ($enrollment -eq 'yes') {
      if ($noninteractive) {
        Write-Log INFO 'Service installed; browser-approved enrollment is pending.'
        Write-Host "Run: powershell -NoProfile -ExecutionPolicy Bypass -File `"$($C.EnrollScript)`""
      } else {
        Invoke-BridgeEnroll $C
        Write-Log OK 'Browser-approved enrollment complete'
      }
    } else {
      Write-Log OK 'Existing enrollment preserved'
    }

    Write-Step 9 'Ready'
    $enrolled = (Test-Path -LiteralPath $C.TokenFile) -and ((Get-Item -LiteralPath $C.TokenFile).Length -gt 0)
    if ($enrolled) {
      Set-OwnerOnlyAcl $C.TokenFile
      Start-BridgeService $C
      if (-not (Wait-BridgeReady $C)) {
        Fail "Service did not start. Inspect: $($C.LogDir) (bridge.err.log), Get-ScheduledTask $serviceName`n$(Get-LogTail (Join-Path $C.LogDir 'bridge.err.log'))"
      }
      Write-Log OK "Service running: $serviceName (Scheduled Task, starts at logon)"
    } else {
      Write-Log INFO "Task $serviceName starts once enrollment completes (the enroll script starts it)."
    }
    Write-Log INFO "Logs: $($C.LogDir)"
    Write-Log INFO "Hub-specific CLI: $($C.CtlWrapper)"
    Write-Log INFO "Re-enroll later: powershell -NoProfile -ExecutionPolicy Bypass -File `"$($C.EnrollScript)`""
  } finally {
    if ($workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($lockHeld) { Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

$HeimdallInstallStatus = 0
if ($Help) {
  Show-HeimdallUsage
} else {
  $ErrorActionPreference = 'Stop'
  try {
    Invoke-HeimdallInstaller @{
      Hub = $Hub; Version = $Version; DryRun = [bool]$DryRun; Uninstall = [bool]$Uninstall; ReEnroll = [bool]$ReEnroll
      KeepEnrollment = [bool]$KeepEnrollment; NonInteractive = [bool]$NonInteractive; FromDir = $FromDir
    }
  } catch {
    $HeimdallInstallStatus = 1
    Write-Host ''
    if (Test-HeimdallFailure $_) {
      Write-Log ERROR $_.Exception.Message.Substring(18)
    } else {
      Write-Log ERROR $_.Exception.Message
      Write-Host $_.InvocationInfo.PositionMessage
    }
  }
}
if ($HeimdallInstallStatus -ne 0) {
  # Exit only when run as a script file; under the scriptblock one-liner `exit`
  # would close the operator's PowerShell window, so set LASTEXITCODE instead.
  if ($PSCommandPath) { exit $HeimdallInstallStatus }
  $global:LASTEXITCODE = $HeimdallInstallStatus
}
