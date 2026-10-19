# Hermetic test of scripts/install.ps1 (Windows). Runs the installer as a child
# process against a stub Hub + release mirror on a random loopback port, with fake
# ham-bridge/ham-pty-host/ham-ctl binaries (tests/windows/fake_bridge.cs) that
# record argv and environment. APPDATA/LOCALAPPDATA point into a temp profile.
# It registers ONE real per-user Scheduled Task, named after the random-port Hub
# (heimdall-bridge-127-0-0-1-<port>), and removes it, its processes and the temp
# tree at the end. Nothing else on the machine is touched.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\install_ps1_test.ps1 [-Engine pwsh]
#
# -Engine picks the PowerShell that runs install.ps1 (default: the one running
# this test), so CI covers Windows PowerShell 5.1 and PowerShell 7.
[CmdletBinding()]
param([string]$Engine = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repo 'scripts\install.ps1'
if (-not $Engine) { $Engine = (Get-Process -Id $PID).Path }
elseif (-not (Test-Path $Engine)) { $Engine = (Get-Command $Engine).Source }

$root = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-ps1-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fake = Join-Path $root 'fake'
$mirror = Join-Path $root 'mirror'
$roaming = Join-Path $root 'home\Roaming'
$local = Join-Path $root 'home\Local'
$fakeLog = Join-Path $root 'fake-calls.log'
foreach ($d in @($fake, $mirror, $roaming, $local, (Join-Path $root 'out'))) { New-Item -ItemType Directory -Force $d | Out-Null }
$script:failures = 0
$script:checks = 0

function Check {
  param([bool]$Condition, [string]$Message, [string]$Detail = '')
  $script:checks++
  if ($Condition) { Write-Host "ok   - $Message" }
  else {
    $script:failures++
    Write-Host "FAIL - $Message"
    if ($Detail) { Write-Host ($Detail -split "`n" | ForEach-Object { "       $_" } | Out-String) }
  }
}

function Get-FreePort {
  $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

$script:runN = 0
function Invoke-Installer {
  param([string[]]$Arguments, [hashtable]$ExtraEnv = @{})
  $script:runN++
  $out = Join-Path $root "out\run$($script:runN).out"
  $err = Join-Path $root "out\run$($script:runN).err"
  $vars = @{ APPDATA = $roaming; LOCALAPPDATA = $local; FAKE_LOG = $fakeLog; HEIMDALL_NON_INTERACTIVE = $null; FAKE_PROBE_FAIL = $null; HEIMDALL_INSTALL_TEST_RELEASES = $null }
  foreach ($k in $ExtraEnv.Keys) { $vars[$k] = $ExtraEnv[$k] }
  $saved = @{}
  foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
  try {
    $argLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installer`"") + ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } })) -join ' '
    $p = Start-Process -FilePath $Engine -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -RedirectStandardInput (Join-Path $root 'empty-stdin.txt')
    $null = $p.Handle
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "installer run $($script:runN) timed out" }
    $text = (Get-Content -Raw $out) + (Get-Content -Raw $err)
    return @{ Code = $p.ExitCode; Out = "$text" }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
}

function Get-Calls {
  param([string]$Path, [string]$Kind)
  if (-not (Test-Path $Path)) { return @() }
  return @(Get-Content $Path | Where-Object { $_.StartsWith("$Kind`t") } | ForEach-Object { , ($_ -split "`t") })
}

function Get-FieldValue {
  param([string[]]$Call, [string]$Name)
  $i = [Array]::IndexOf($Call, $Name)
  if ($i -ge 0 -and $i + 1 -lt $Call.Count) { return $Call[$i + 1] }
  $kv = $Call | Where-Object { $_.StartsWith("$Name=") } | Select-Object -First 1
  if ($kv) { return $kv.Substring($Name.Length + 1) }
  return $null
}

function Test-OwnerOnly {
  param([string]$Path)
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $acl = Get-Acl -LiteralPath $Path
  $ids = @($acl.Access | ForEach-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { "$($_.IdentityReference)" } } | Select-Object -Unique)
  return $acl.AreAccessRulesProtected -and $ids.Count -eq 1 -and $ids[0] -eq $sid
}

function New-Bundle {
  param([string]$Zip, [hashtable]$Entries)
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $fs = [IO.File]::Open($Zip, [IO.FileMode]::Create)
  try {
    $z = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try { foreach ($k in $Entries.Keys) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $Entries[$k], $k) } } finally { $z.Dispose() }
  } finally { $fs.Dispose() }
}

$hubProc = $null
$task = $null
try {
  Set-Content -Path (Join-Path $root 'empty-stdin.txt') -Value '' -Encoding ASCII
  # ---- fakes (compiled by Windows PowerShell: only it can emit a console exe) ----
  $fakeExe = Join-Path $fake 'ham-bridge.exe'
  $cs = Join-Path $PSScriptRoot 'fake_bridge.cs'
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Add-Type -Path '$cs' -OutputAssembly '$fakeExe' -OutputType ConsoleApplication"
  if (-not (Test-Path $fakeExe)) { throw 'could not compile the fake bridge' }
  Copy-Item $fakeExe (Join-Path $fake 'ham-pty-host.exe')
  Copy-Item $fakeExe (Join-Path $fake 'ham-ctl.exe')
  $hubExe = Join-Path $root 'fake-hub.exe'
  Copy-Item $fakeExe $hubExe
  $supervisor = Join-Path $root 'apply-bridge-update.ps1'
  Set-Content -Path $supervisor -Value 'exit 0' -Encoding ASCII

  $port = Get-FreePort
  $hubProc = Start-Process -FilePath $hubExe -ArgumentList @('serve', "$port", "`"$mirror`"") -WindowStyle Hidden -PassThru
  $hub = "http://127.0.0.1:$port"
  $svc = "heimdall-bridge-127-0-0-1-$port"
  $task = $svc
  $stateDir = Join-Path $roaming "heimdall\bridges\$svc"
  $dataDir = Join-Path $local "heimdall\bridges\$svc"
  $binDir = Join-Path $dataDir 'bin'
  for ($i = 0; $i -lt 50; $i++) {
    try { $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $port); $c.Close(); break } catch { Start-Sleep -Milliseconds 100 }
  }
  Write-Host "engine: $Engine"
  Write-Host "stub hub: $hub (task $svc)"

  # ---- parse / help / validation / dry run ----
  $t = $null; $e = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$t, [ref]$e)
  Check ($e.Count -eq 0) 'install.ps1 parses' ($e | Out-String)
  Check (@([IO.File]::ReadAllBytes($installer) | Where-Object { $_ -gt 127 }).Count -eq 0) 'install.ps1 is pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)'
  $r = Invoke-Installer @('-Help')
  Check ($r.Code -eq 0 -and $r.Out -match 'Usage: install\.ps1') '-Help prints usage' $r.Out
  $r = Invoke-Installer @('-Hub', 'https://user:pw@hub.example.com', '-DryRun')
  Check ($r.Code -eq 1 -and $r.Out -match 'Invalid Hub URL') 'credentials in the Hub URL are rejected' $r.Out
  $r = Invoke-Installer @('-Hub', 'https://hub.example.com/sub', '-DryRun')
  Check ($r.Code -eq 1 -and $r.Out -match 'Invalid Hub URL') 'a Hub URL path is rejected' $r.Out
  $r = Invoke-Installer @('-DryRun') @{ HEIMDALL_NON_INTERACTIVE = '1' }
  Check ($r.Code -eq 1 -and $r.Out -match '-Hub is required in non-interactive mode') 'non-interactive without -Hub fails' $r.Out
  $r = Invoke-Installer @('-Hub', 'HTTPS://Hub.Example.COM:443/', '-DryRun')
  Check ($r.Code -eq 0 -and $r.Out -match 'Service: heimdall-bridge-hub-example-com ' -and $r.Out -match '\[PLAN\] Download heimdall-local-windows-amd64-LATEST\.zip') '-DryRun canonicalizes the Hub and plans the release download' $r.Out
  $r = Invoke-Installer @('-Hub', 'http://[::1]:8080', '-DryRun', '-Version', 'v1.2.3')
  Check ($r.Code -eq 0 -and $r.Out -match 'heimdall-bridge---1-8080' -and $r.Out -match 'windows-amd64-v1\.2\.3\.zip') 'IPv6 Hub naming and -Version in the plan' $r.Out
  Check (-not (Test-Path (Join-Path $roaming 'heimdall'))) 'dry runs write nothing'

  # ---- failures before anything is replaced ----
  $closed = Get-FreePort
  $r = Invoke-Installer @('-Hub', "http://127.0.0.1:$closed", '-FromDir', $fake, '-NonInteractive')
  Check ($r.Code -eq 1 -and $r.Out -match "Hub http://127\.0\.0\.1:$closed not reachable \(gave up after") 'unreachable Hub fails with the exact reason' $r.Out
  $r = Invoke-Installer @('-Hub', $hub, '-FromDir', $fake, '-NonInteractive') @{ FAKE_PROBE_FAIL = '1' }
  Check ($r.Code -eq 1 -and $r.Out -match 'cannot reach .* through its own TLS transport') 'failed --probe-hub stops the install' $r.Out
  Check (-not (Get-ScheduledTask -TaskPath '\' -TaskName $svc -ErrorAction SilentlyContinue) -and -not (Test-Path $binDir)) 'nothing installed after a failed preflight'

  # ---- fresh install from local binaries, with (fake) enrollment ----
  $r = Invoke-Installer @('-Hub', $hub, '-FromDir', $fake)
  Check ($r.Code -eq 0) 'fresh -FromDir install succeeds' $r.Out
  Check ($r.Out -match 'ABCD-EFGH-JKLM-NP' -and $r.Out -match 'Browser-approved enrollment complete') 'enrollment runs interactively and its pairing code is shown' $r.Out
  Check ($r.Out -match "\[OK\] Service running: $svc") 'service reported running' $r.Out
  $st = Get-ScheduledTask -TaskPath '\' -TaskName $svc -ErrorAction SilentlyContinue
  Check ($st -and "$($st.State)" -eq 'Running') 'Scheduled Task registered and running'
  if ($st) {
    $a = $st.Actions[0]
    Check ($a.Execute -match 'wscript\.exe$' -and $a.Arguments -match 'bridge-service\.js') 'task runs the hidden wscript launcher' "$($a.Execute) $($a.Arguments)"
    Check (@($st.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -eq 1) 'task starts at logon'
    Check ("$($st.Principal.RunLevel)" -eq 'Limited' -and "$($st.Principal.LogonType)" -eq 'Interactive') 'task runs as the user without elevation'
    Check ($st.Settings.RestartCount -gt 0 -and $st.Settings.ExecutionTimeLimit -eq 'PT0S') 'task restarts on failure and has no time limit'
  }
  $ports = @(foreach ($x in (Get-Content -Raw (Join-Path $stateDir 'ports.json') | ConvertFrom-Json)) { [int]$x })
  Check ($ports.Count -eq 2 -and $ports[0] -ne $ports[1]) "ports.json holds a port pair ($($ports -join ', '))"
  Check ((Get-Content -Raw (Join-Path $stateDir 'hub-url')).Trim() -eq $hub) 'hub-url recorded'
  $cfg = Get-Content -Raw (Join-Path $stateDir 'config.toml')
  Check ($cfg -match "daemon_url = `"$([regex]::Escape($hub))`"" -and $cfg -match ('data_dir = "' + [regex]::Escape($dataDir.Replace('\', '/')) + '"')) 'config.toml carries the Hub and forward-slash data dir' $cfg
  Check ((Test-OwnerOnly $stateDir) -and (Test-OwnerOnly $dataDir) -and (Test-OwnerOnly (Join-Path $stateDir 'bridge-token'))) 'state dir, data dir and token are owner-only'
  Check (Test-Path (Join-Path $stateDir 'enroll.ps1')) 'enroll.ps1 persisted'
  $t = $null; $e = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $stateDir 'enroll.ps1'), [ref]$t, [ref]$e)
  Check ($e.Count -eq 0) 'enroll.ps1 parses' ($e | Out-String)

  $enroll = @(Get-Calls $fakeLog 'ham-bridge' | Where-Object { $_[1] -eq 'enroll' })
  Check ($enroll.Count -eq 1) 'ham-bridge enroll ran once'
  if ($enroll.Count -eq 1) {
    $c = $enroll[0]
    Check ((Get-FieldValue $c '--hub') -eq $hub -and (Get-FieldValue $c '--bridge-token-file') -eq (Join-Path $stateDir 'bridge-token') -and
      (Get-FieldValue $c '--config') -eq (Join-Path $stateDir 'config.toml') -and (Get-FieldValue $c '--data-dir') -eq $dataDir -and
      (Get-FieldValue $c '--port') -eq "$($ports[0])" -and (Get-FieldValue $c '--local-endpoint-port') -eq "$($ports[1])" -and
      (Get-FieldValue $c '--local-run-dir') -eq (Join-Path $dataDir 'run')) 'enroll argv matches install.sh' ($c -join ' | ')
    Check ((Get-FieldValue $c 'HEIMDALL_HAM_PTY_HOST_BIN') -eq (Join-Path $binDir 'ham-pty-host.exe') -and (Get-FieldValue $c 'HEIMDALL_BRIDGE_PTY_HOST') -eq 'true' -and
      (Get-FieldValue $c 'HEIMDALL_HAM_CTL_BIN') -eq (Join-Path $binDir 'ham-ctl.exe') -and (Get-FieldValue $c 'PATH0') -eq $binDir) 'enroll environment carries the tool paths' ($c -join ' | ')
  }
  $probe = @(Get-Calls $fakeLog 'ham-bridge' | Where-Object { $_ -contains '--probe-hub' })
  Check ($probe.Count -ge 1 -and (Get-FieldValue $probe[-1] '--probe-hub') -eq $hub) '--probe-hub preflight ran against the Hub'

  $runtimeLog = Join-Path $dataDir 'fake-calls.log'
  $rt = @(Get-Calls $runtimeLog 'ham-bridge')
  Check ($rt.Count -ge 1) 'the task started ham-bridge'
  if ($rt.Count -ge 1) {
    $c = $rt[-1]
    Check ((Get-FieldValue $c '--hub') -eq $hub -and (Get-FieldValue $c '--bind-host') -eq '127.0.0.1' -and (Get-FieldValue $c '--port') -eq "$($ports[0])" -and
      (Get-FieldValue $c '--bridge-token-file') -eq (Join-Path $stateDir 'bridge-token')) 'service argv' ($c -join ' | ')
    Check ((Get-FieldValue $c 'HEIMDALL_BRIDGE_ENDPOINT') -eq "tcp:127.0.0.1:$($ports[1])" -and (Get-FieldValue $c 'HEIMDALL_BRIDGE_SERVICE_NAME') -eq $svc -and
      (Get-FieldValue $c 'HEIMDALL_HAM_CTL_BIN') -eq (Join-Path $binDir "ham-ctl-$svc.cmd") -and (Get-FieldValue $c 'HEIMDALL_BRIDGE_PTY_HOST') -eq 'true' -and
      (Get-FieldValue $c 'HEIMDALL_HAM_PTY_HOST_BIN') -eq (Join-Path $binDir 'ham-pty-host.exe') -and (Get-FieldValue $c 'PATH0') -eq $binDir) 'service environment matches install.sh unit' ($c -join ' | ')
  }

  # ---- per-Hub ham-ctl wrapper ----
  $wrapper = Join-Path $binDir "ham-ctl-$svc.cmd"
  $savedLog = $env:FAKE_LOG; $savedEp = $env:HEIMDALL_BRIDGE_ENDPOINT
  $env:FAKE_LOG = $fakeLog; $env:HEIMDALL_BRIDGE_ENDPOINT = $null
  try { & $wrapper tasks list 'a b' | Out-Null; $wrc = $LASTEXITCODE } finally { $env:FAKE_LOG = $savedLog; $env:HEIMDALL_BRIDGE_ENDPOINT = $savedEp }
  $ctl = @(Get-Calls $fakeLog 'ham-ctl')
  Check ($wrc -eq 0 -and $ctl.Count -ge 1 -and (Get-FieldValue $ctl[-1] '--config') -eq (Join-Path $stateDir 'config.toml') -and $ctl[-1] -contains 'a b' -and
    (Get-FieldValue $ctl[-1] 'HEIMDALL_BRIDGE_ENDPOINT') -eq "tcp:127.0.0.1:$($ports[1])") 'ham-ctl wrapper adds --config and the endpoint' ($ctl | ForEach-Object { $_ -join ' | ' } | Out-String)

  # ---- verified release path (stub mirror), keeping the enrollment ----
  $tag = 'v9.9.9'
  $bundle = Join-Path $root "heimdall-local-windows-amd64-$tag.zip"
  New-Bundle $bundle ([ordered]@{
      'bin/ham-bridge.exe' = $fakeExe; 'bin/ham-pty-host.exe' = $fakeExe; 'bin/ham-ctl.exe' = $fakeExe
      'scripts/apply-bridge-update.ps1' = $supervisor; 'README.md' = $supervisor
    })
  $unsafe = Join-Path $root 'heimdall-local-windows-amd64-v9.9.8.zip'
  New-Bundle $unsafe ([ordered]@{ 'bin/ham-bridge.exe' = $fakeExe; 'bin/ham-pty-host.exe' = $fakeExe; 'bin/ham-ctl.exe' = $fakeExe; '../evil.txt' = $supervisor })
  foreach ($v in @('v9.9.9', 'v9.9.8')) {
    $d = Join-Path $mirror "rel\download\$v"
    New-Item -ItemType Directory -Force $d | Out-Null
    $src = $bundle; if ($v -eq 'v9.9.8') { $src = $unsafe }
    Copy-Item $src (Join-Path $d "heimdall-local-windows-amd64-$v.zip")
    $h = (Get-FileHash -Algorithm SHA256 $src).Hash.ToLowerInvariant()
    Set-Content -Path (Join-Path $d 'SHA256SUMS') -Encoding ASCII -Value "$h  heimdall-local-windows-amd64-$v.zip`n0000  heimdall-local-linux-amd64-$v.tar.gz"
  }
  $releases = @(
    @{ tag_name = 'v9.9.10'; draft = $false; prerelease = $true; assets = @(@{ name = 'SHA256SUMS' }, @{ name = 'heimdall-local-windows-amd64-v9.9.10.zip' }) },
    @{ tag_name = 'v9.9.9'; draft = $false; prerelease = $false; assets = @(@{ name = 'SHA256SUMS' }, @{ name = 'heimdall-local-windows-amd64-v9.9.9.zip' }) }
  )
  Set-Content -Path (Join-Path $mirror 'rel\releases.json') -Encoding ASCII -Value (ConvertTo-Json -Depth 5 $releases)
  $relEnv = @{ HEIMDALL_INSTALL_TEST_RELEASES = "$hub/rel" }
  $r = Invoke-Installer @('-Hub', $hub, '-KeepEnrollment') $relEnv
  Check ($r.Code -eq 0 -and $r.Out -match 'Downloading v9\.9\.9' -and $r.Out -match 'Release checksum and bundle verified' -and $r.Out -match 'Existing enrollment preserved' -and $r.Out -match 'Service running') 'release install resolves the newest promoted release, verifies it and keeps enrollment' $r.Out
  $ports2 = @(foreach ($x in (Get-Content -Raw (Join-Path $stateDir 'ports.json') | ConvertFrom-Json)) { [int]$x })
  Check (($ports2 -join ',') -eq ($ports -join ',')) 'reinstall keeps this Hub''s ports'
  Check (Test-Path (Join-Path $dataDir 'updates\apply-bridge-update.ps1')) 'update supervisor installed to <data>\updates'
  Check (Test-Path (Join-Path $local "heimdall\cache\releases\heimdall-local-windows-amd64-$tag.zip")) 'verified bundle cached'
  Check (@(Get-Calls $fakeLog 'ham-bridge' | Where-Object { $_[1] -eq 'enroll' }).Count -eq 1) '-KeepEnrollment does not enroll again'
  $r = Invoke-Installer @('-Hub', $hub, '-NonInteractive') $relEnv
  Check ($r.Code -eq 0 -and $r.Out -match 'Using cached heimdall-local-windows-amd64-v9\.9\.9\.zip' -and $r.Out -match 'Existing enrollment preserved') 'second install reuses the cached bundle; -NonInteractive keeps enrollment' $r.Out

  $mz = Join-Path $mirror 'rel\download\v9.9.9\heimdall-local-windows-amd64-v9.9.9.zip'
  [IO.File]::AppendAllText($mz, 'tampered')
  [IO.File]::AppendAllText((Join-Path $local "heimdall\cache\releases\heimdall-local-windows-amd64-$tag.zip"), 'tampered')
  $r = Invoke-Installer @('-Hub', $hub, '-NonInteractive', '-Version', 'v9.9.9') $relEnv
  Check ($r.Code -eq 1 -and $r.Out -match 'SHA-256 verification failed; nothing installed') 'tampered bundle is refused (and a tampered cache is not trusted)' $r.Out
  $st = Get-ScheduledTask -TaskPath '\' -TaskName $svc -ErrorAction SilentlyContinue
  Check ($st -and "$($st.State)" -eq 'Running') 'the running service is untouched by a refused bundle'
  $r = Invoke-Installer @('-Hub', $hub, '-NonInteractive', '-Version', 'v9.9.8') $relEnv
  Check ($r.Code -eq 1 -and $r.Out -match 'Unsafe path in release bundle') 'a bundle with a ../ entry is refused' $r.Out
  Check (-not (Test-Path (Join-Path ([IO.Path]::GetTempPath()) 'evil.txt'))) 'nothing written outside the work dir'

  # ---- install lock ----
  $lock = Join-Path $roaming 'heimdall\bridges\.install-lock'
  New-Item -ItemType Directory $lock | Out-Null
  Set-Content -Path (Join-Path $lock 'pid') -Value "$PID" -Encoding ASCII
  $r = Invoke-Installer @('-Hub', $hub, '-FromDir', $fake, '-NonInteractive')
  Check ($r.Code -eq 1 -and $r.Out -match 'Another installer is running') 'a live install lock blocks a second run' $r.Out
  Set-Content -Path (Join-Path $lock 'pid') -Value '999999' -Encoding ASCII
  $r = Invoke-Installer @('-Hub', $hub, '-FromDir', $fake, '-NonInteractive')
  Check ($r.Code -eq 0 -and $r.Out -match 'Removing stale installer lock') 'a stale lock (dead owner) is taken over' $r.Out
  Check (-not (Test-Path $lock)) 'lock released after the run'

  # ---- uninstall ----
  $r = Invoke-Installer @('-Hub', $hub, '-Uninstall')
  Check ($r.Code -eq 0 -and $r.Out -match 'Uninstalled\. Enrollment and agent data preserved\.') '-Uninstall succeeds' $r.Out
  Check (-not (Get-ScheduledTask -TaskPath '\' -TaskName $svc -ErrorAction SilentlyContinue)) 'task removed'
  Check (-not (Test-Path $binDir)) 'binaries removed'
  Check ((Test-Path (Join-Path $stateDir 'bridge-token')) -and (Test-Path (Join-Path $stateDir 'config.toml'))) 'credentials and config kept'
  $left = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($local, [StringComparison]::OrdinalIgnoreCase) })
  Check ($left.Count -eq 0) 'no bridge process left running' ($left | ForEach-Object { "$($_.ProcessId) $($_.ExecutablePath)" } | Out-String)
} catch {
  $script:failures++
  Write-Host "FAIL - test harness error: $($_.Exception.Message)"
  Write-Host $_.InvocationInfo.PositionMessage
} finally {
  if ($task -and (Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction SilentlyContinue)) {
    Stop-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath '\' -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process | Where-Object {
    ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) -or
    ($_.Name -eq 'wscript.exe' -and $_.CommandLine -and $_.CommandLine.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0)
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  if ($hubProc) { Stop-Process -Id $hubProc.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "$($script:checks - $script:failures)/$($script:checks) checks passed"
if ($script:failures -gt 0) { exit 1 }
exit 0
