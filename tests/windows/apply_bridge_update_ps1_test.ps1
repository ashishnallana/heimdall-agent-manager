# Tests of scripts/apply-bridge-update.ps1, the Windows update supervisor.
#
#   pwsh -NoProfile -File tests/windows/apply_bridge_update_ps1_test.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\apply_bridge_update_ps1_test.ps1
#
# Runs on any PowerShell (5.1 or 7, Windows or not). The script runs as a child
# process for argument handling, and is dot-sourced for its pure helpers
# (SemVer, command-line splitting, PTY ownership on a fabricated snapshot).
# On a non-Windows PowerShell 7 it also runs --stop-pty-hosts-only against
# real fake PTY hosts (the Get-Process reader) and the apply flow end to end
# with stop/restart hooks and a loopback health server. Everything lives in a
# temp directory that is removed at the end; no service or task is touched.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$supervisor = Join-Path $repo 'scripts/apply-bridge-update.ps1'
$engine = (Get-Process -Id $PID).Path
$onWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$root = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-supervisor-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $root | Out-Null
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

# Run the supervisor as the Bridge does (-File, flags as separate argv words).
function Invoke-Supervisor {
  param([string[]]$Arguments, [hashtable]$Env = @{})
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $engine
  $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $supervisor) + $Arguments
  if ($psi.PSObject.Properties['ArgumentList'] -and $null -ne $psi.ArgumentList) {
    foreach ($a in $all) { $psi.ArgumentList.Add($a) }
  } else {
    $psi.Arguments = (($all | ForEach-Object { if ($_ -match '^[^\s"]+$') { $_ } else { '"' + $_.Replace('"', '\"') + '"' } }) -join ' ')
  }
  foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'supervisor did not finish in 120s' }
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

try {
  # --- Parse ----------------------------------------------------------------
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($supervisor, [ref]$null, [ref]$errors)
  Check ($errors.Count -eq 0) 'script parses' (($errors | Out-String))
  $bytes = [IO.File]::ReadAllBytes($supervisor)
  Check (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'script is ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)'

  # --- Caller contract ------------------------------------------------------
  $r = Invoke-Supervisor @('--help')
  Check ($r.Code -eq 0 -and $r.Out -match '--interface N' -and $r.Out -match '--from-version VER' -and $r.Out -match '--stop-pty-hosts-only') '--help documents the versioned interface' $r.Out

  $data = Join-Path $root 'refusals'
  New-Item -ItemType Directory -Force $data | Out-Null
  $refusals = @(
    @(@('--bogus'), 'Unknown flag: --bogus'),
    @(@('--interface', '3', '--from-version', '0.5.0', '--to-version', '0.6.0'), 'Unsupported supervisor interface 3: this apply-bridge-update.ps1 supports interfaces 1-2; refusing before any change'),
    @(@('--interface', 'x'), 'Invalid --interface value: x (expected a positive integer)'),
    @(@('--interface', '01'), 'Invalid --interface value: 01 (expected a positive integer)'),
    @(@('--interface', '2', '--from-version', '0.5.1'), 'Supervisor interface 2 requires --from-version and --to-version'),
    @(@('--interface', '2', '--to-version', '0.5.1', '--stop-pty-hosts-only'), 'Supervisor interface 2 requires --from-version and --to-version'),
    @(@('--data-dir'), 'Missing value for --data-dir'),
    @(@('--health-method', 'POST'), 'Unsupported health method: POST (expected GET or OPTIONS)')
  )
  foreach ($case in $refusals) {
    $r = Invoke-Supervisor (@('--data-dir', $data, '--stage-dir', (Join-Path $data 'nothing')) + $case[0])
    Check ($r.Code -eq 2 -and $r.Err.Trim() -eq $case[1] -and $r.Out -eq '') "refuses $($case[0] -join ' ') with exit 2 before any step" "exit=$($r.Code) err=$($r.Err) out=$($r.Out)"
  }
  Check (@(Get-ChildItem -LiteralPath $data -Force).Count -eq 0) 'refusals left the data dir untouched'

  # --- Pure helpers (dot-sourced) -------------------------------------------
  . $supervisor
  $semver = @(
    @('0.5.0', '0.5.1', -1), @('0.5.1', '0.5.0', 1), @('v0.5.0', '0.5.0', 0), @('0.5.0+b1', '0.5.0+b2', 0),
    @('0.5.0-rc.1', '0.5.0', -1), @('0.5.0-alpha', '0.5.0-alpha.1', -1), @('0.5.0-alpha.1', '0.5.0-alpha.beta', -1),
    @('0.5.0-beta.2', '0.5.0-beta.11', -1), @('0.5.0-rc.1', '0.5.0-RC.1', 1), @('1.0.0', '0.99.99', 1),
    @('0.10.0', '0.9.0', 1), @('99999999999999999999.0.0', '99999999999999999998.0.0', 1),
    @('0.5', '0.5.0', $null), @('dev', '0.5.0', $null), @('01.0.0', '1.0.0', $null)
  )
  $bad = @()
  foreach ($c in $semver) {
    $got = Compare-SemVer $c[0] $c[1]
    if (-not (($null -eq $got -and $null -eq $c[2]) -or ($null -ne $got -and $null -ne $c[2] -and $got -eq $c[2]))) { $bad += "$($c[0]) vs $($c[1]): got $got want $($c[2])" }
  }
  Check ($bad.Count -eq 0) "SemVer precedence table ($($semver.Count) cases, same as the .sh Test 11)" ($bad -join "`n")
  Check ((Test-VersionBefore '0.5.0' '0.7.0') -and -not (Test-VersionBefore 'dev' '0.7.0') -and (Test-VersionAtLeast '0.7.0' '0.7.0') -and -not (Test-VersionAtLeast 'dev' '0.1.0')) 'range tests are false for non-SemVer versions'

  $argvCases = @(
    @('"C:\Program Files\x\ham-pty-host.exe" daemon --socket "C:\Users\A B\run\pty-host.sock"', @('C:\Program Files\x\ham-pty-host.exe', 'daemon', '--socket', 'C:\Users\A B\run\pty-host.sock')),
    @('a\\\"b "c\\" d', @('a\"b', 'c\', 'd')),
    @('x "a ""q"" b" y', @('x', 'a "q" b', 'y')),
    @('  lead   trail  ', @('lead', 'trail')),
    @('C:\dir\ham-pty-host.exe --socket=C:/r/p.sock run', @('C:\dir\ham-pty-host.exe', '--socket=C:/r/p.sock', 'run')),
    @('', @())
  )
  $bad = @()
  foreach ($c in $argvCases) {
    $got = @(Split-CommandLine $c[0])
    if (($got -join '|') -cne ($c[1] -join '|') -or $got.Count -ne $c[1].Count) { $bad += "[$($c[0])] -> [$($got -join '|')]" }
  }
  Check ($bad.Count -eq 0) 'Split-CommandLine follows CommandLineToArgvW rules' ($bad -join "`n")

  # Ownership on a fabricated snapshot. Data dir is a private install (its parent is "bridges").
  $sep = [IO.Path]::DirectorySeparatorChar
  $dd = Get-CanonicalPath (Join-Path $root "bridges${sep}svc")
  $other = Get-CanonicalPath (Join-Path $root "bridges${sep}other")
  $sock = Get-CanonicalPath (Join-Path $root "run${sep}pty-host.sock")
  function Rec { param($Id, $Parent, $Born, $Exe, $Cmd) [pscustomobject]@{ Id = $Id; Parent = $Parent; Born = "$Born"; Exe = $Exe; CommandLine = $Cmd } }
  $q = { param($p) '"' + $p + '"' }
  $records = @(
    (Rec 100 1 1000 "$dd${sep}bin${sep}ham-pty-host.exe" ((& $q "$dd${sep}bin${sep}ham-pty-host.exe") + ' daemon --socket ' + (& $q "$root${sep}elsewhere.sock"))),
    (Rec 101 100 1001 'C:\Windows\System32\conhost.exe' 'conhost.exe --headless'),
    (Rec 102 101 1002 'C:\node.exe' 'node agent.js'),
    (Rec 103 100 900 'C:\reused.exe' 'reused.exe'),
    (Rec 200 1 1000 "$dd${sep}bin.old${sep}ham-pty-host.exe" ((& $q "$dd${sep}bin.old${sep}ham-pty-host.exe") + ' run')),
    (Rec 300 1 1000 "$other${sep}bin${sep}ham-pty-host.exe" ((& $q "$other${sep}bin${sep}ham-pty-host.exe") + ' daemon --socket ' + (& $q "$root${sep}o.sock"))),
    (Rec 301 300 1001 'C:\agent.exe' 'agent.exe'),
    (Rec 400 1 1000 'C:\tools\ham-pty-host.exe' ('C:\tools\ham-pty-host.exe daemon --socket=' + $sock.Replace('\', '/'))),
    (Rec 500 1 1000 "$dd${sep}bin${sep}ham-pty-host.exe" ((& $q "$dd${sep}bin${sep}ham-pty-host.exe") + ' --socket x stop')),
    (Rec 600 1 1000 "$dd${sep}tools${sep}ham-pty-host.exe" ((& $q "$dd${sep}tools${sep}ham-pty-host.exe") + ' daemon')),
    (Rec 700 1 1000 '/usr/bin/bash' ('/usr/bin/bash ' + (& $q "$dd${sep}bin${sep}ham-pty-host") + ' daemon --socket ' + (& $q "$root${sep}t.sock")))
  )
  $sel = Select-OwnedPtyProcesses -Records $records -DataDir $dd -ExpectedSocket $sock -PrivateInstall $true
  $ids = @($sel.Owned.Keys | Sort-Object) -join ','
  Check ($ids -eq '100,101,102,200,400,700') 'owns hosts by bin path (bin, bin.old, interpreter-run) or socket, plus descendants' "owned=$ids"
  Check (-not $sel.Owned.ContainsKey(103)) 'a child that predates its parent (reused parent PID) is not a descendant'
  Check (-not $sel.Owned.ContainsKey(300) -and -not $sel.Owned.ContainsKey(301)) "another bridge's host and its agents are left alone"
  Check (-not $sel.Owned.ContainsKey(500) -and -not $sel.Owned.ContainsKey(600)) 'a ham-pty-host client call or a binary outside bin* is not a host'
  $sel = Select-OwnedPtyProcesses -Records $records -DataDir $dd -ExpectedSocket '' -PrivateInstall $false
  $ids = @($sel.Owned.Keys | Sort-Object) -join ','
  Check ($ids -eq '') 'a shared (non-private) data dir owns nothing by binary path' "owned=$ids"

  # --- Live checks with real processes (PowerShell 7 off Windows) ------------
  if (-not $onWindows -and (Get-Process -Id $PID).PSObject.Properties['CommandLine']) {
    $live = Join-Path $root "bridges${sep}live"
    $bin = Join-Path $live 'bin'
    New-Item -ItemType Directory -Force $bin | Out-Null
    $hostScript = Join-Path $bin 'ham-pty-host'
    # A fake PTY host: a daemon with one agent child; "stop" is ignored, so the
    # supervisor must fall through to terminating it.
    [IO.File]::WriteAllText($hostScript, "#!/usr/bin/env bash`nif [ `"`$1`" = --socket ] && [ `"`$3`" = stop ]; then exit 0; fi`nsleep 300 & wait`n")
    & chmod +x $hostScript
    $bash = (Get-Command bash).Source
    $sockArg = Join-Path $root 'live.sock'
    $daemon = Start-Process -FilePath $bash -ArgumentList @($hostScript, 'daemon', '--socket', $sockArg) -PassThru
    $foreign = Start-Process -FilePath (Get-Command sleep).Source -ArgumentList @('300') -PassThru
    Start-Sleep -Milliseconds 500
    $agent = @(Get-Process | Where-Object { $_.Parent -and $_.Parent.Id -eq $daemon.Id })
    Check ($agent.Count -eq 1) 'fake PTY host started an agent child'
    $r = Invoke-Supervisor @('--interface', '2', '--from-version', '0.5.0', '--to-version', '0.5.1', '--data-dir', $live, '--stop-pty-hosts-only', '--pty-host-socket', (Join-Path $root 'unused.sock'))
    Start-Sleep -Milliseconds 200
    $daemonGone = $null -eq (Get-Process -Id $daemon.Id -ErrorAction SilentlyContinue)
    $agentGone = ($agent.Count -eq 1) -and ($null -eq (Get-Process -Id $agent[0].Id -ErrorAction SilentlyContinue))
    Check ($r.Code -eq 0 -and $daemonGone -and $agentGone) '--stop-pty-hosts-only stops the owned host and its agent' "exit=$($r.Code) out=$($r.Out) err=$($r.Err)"
    Check ($r.Out -match 'Version hooks \(stop-pty-hosts-only\): interface 2, from 0\.5\.0 to 0\.5\.1' -and $r.Out -match 'direction: upgrade' -and $r.Out -match 'hook: from-version 0\.5\.0 \(0\.5 line\)') 'stop-pty-hosts-only runs the version hooks' $r.Out
    Check ($r.Out -match "stopping bridge-owned PTY processes: .*$($daemon.Id).* \(found through process\)") 'logs the stopped PIDs and the reader' $r.Out
    Check ($null -ne (Get-Process -Id $foreign.Id -ErrorAction SilentlyContinue)) 'an unrelated process is not touched'
    Stop-Process -Id $foreign.Id -Force -ErrorAction SilentlyContinue

    $r = Invoke-Supervisor @('--data-dir', $live, '--stop-pty-hosts-only')
    Check ($r.Code -eq 0 -and $r.Out -match 'Legacy caller \(interface 1, no --from-version\): stop-pty-hosts-only') 'legacy caller (install.ps1 argv) is accepted with nothing to stop' "exit=$($r.Code) $($r.Out) $($r.Err)"
    $r = Invoke-Supervisor @('--data-dir', $live, '--stop-pty-hosts-only') @{ PTY_PROCESS_READER = 'none' }
    Check ($r.Code -eq 3 -and $r.Err -match 'no process was stopped') 'exit 3 when no process reader is available' "exit=$($r.Code) $($r.Err)"

    # --- Apply flow with hooks and a loopback health server -----------------
    function New-Install {
      param([string]$Name)
      $d = Join-Path $root "bridges${sep}$Name"
      $b = Join-Path $d 'bin'
      $s = Join-Path $d "updates${sep}stage${sep}bin"
      New-Item -ItemType Directory -Force $b, $s | Out-Null
      foreach ($f in @('ham-bridge.exe', 'ham-ctl.exe', 'ham-pty-host.exe')) {
        [IO.File]::WriteAllText((Join-Path $b $f), "old $f")
        [IO.File]::WriteAllText((Join-Path $s $f), "new $f")
      }
      foreach ($f in @('bridge-service.js', 'bridge-run.cmd', "ham-ctl-$Name.cmd")) { [IO.File]::WriteAllText((Join-Path $b $f), "installer $f") }
      $calls = Join-Path $d 'hook-calls.log'
      foreach ($hook in @('stop', 'restart')) {
        $h = Join-Path $d "$hook-hook.sh"
        [IO.File]::WriteAllText($h, "#!/usr/bin/env bash`necho `"$hook `$*`" >> '$calls'`n")
        & chmod +x $h
      }
      return @{ Dir = $d; Bin = $b; Stage = (Split-Path -Parent $s); Calls = $calls }
    }
    function Start-HealthServer {
      param([int]$Status)
      $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
      $l.Start()
      $port = $l.LocalEndpoint.Port
      $l.Stop()
      $job = Start-ThreadJob -ArgumentList $port, $Status -ScriptBlock {
        param($port, $status)
        $h = New-Object Net.HttpListener
        $h.Prefixes.Add("http://127.0.0.1:$port/")
        $h.Start()
        # Bounded and interruptible: Stop-Job lands between the short waits.
        $until = [DateTime]::UtcNow.AddSeconds(60)
        try {
          while ([DateTime]::UtcNow -lt $until) {
            $t = $h.GetContextAsync()
            while (-not $t.Wait(200)) { if ([DateTime]::UtcNow -ge $until) { return } }
            $t.Result.Response.StatusCode = $status
            $t.Result.Response.Close()
          }
        } finally { $h.Close() }
      }
      Start-Sleep -Milliseconds 300
      return @{ Port = $port; Job = $job }
    }

    $inst = New-Install 'apply-ok'
    $srv = Start-HealthServer 200
    $r = Invoke-Supervisor @('--interface', '2', '--from-version', '0.5.0', '--to-version', '0.5.1', '--data-dir', $inst.Dir, '--stage-dir', $inst.Stage,
      '--bridge-port', "$($srv.Port)", '--bridge-pid', '999999', '--stop-hook', (Join-Path $inst.Dir 'stop-hook.sh'), '--restart-hook', (Join-Path $inst.Dir 'restart-hook.sh'), '--health-timeout', '10')
    $calls = ''
    if (Test-Path $inst.Calls) { $calls = [IO.File]::ReadAllText($inst.Calls) }
    Check ($r.Code -eq 0 -and $r.Out -match 'Bridge update completed successfully') 'apply: healthy update succeeds' "exit=$($r.Code) out=$($r.Out) err=$($r.Err)"
    Check ([IO.File]::ReadAllText((Join-Path $inst.Bin 'ham-bridge.exe')) -eq 'new ham-bridge.exe') 'apply: bin holds the staged binaries'
    Check (@(@('bridge-service.js', 'bridge-run.cmd', 'ham-ctl-apply-ok.cmd') | Where-Object { -not (Test-Path (Join-Path $inst.Bin $_)) }).Count -eq 0) 'apply: installer-generated service files survive the swap'
    Check (-not (Test-Path "$($inst.Bin).bak") -and -not (Test-Path $inst.Stage)) 'apply: backup and stage are removed after success'
    Check ($calls -eq "stop 999999`nrestart `n") 'apply: stop hook gets the bridge PID, then the restart hook runs' $calls
    Check ($r.Out -match 'Version hooks \(update\): interface 2, from 0\.5\.0 to 0\.5\.1' -and $r.Out -match 'FROM_VERSION:   0\.5\.0') 'apply: logs the version hooks and versions' $r.Out
    Check ((Test-Path (Join-Path $inst.Dir 'logs/apply-bridge-update.log')) -and ([IO.File]::ReadAllText((Join-Path $inst.Dir 'logs/apply-bridge-update.log')) -match 'Bridge update completed successfully')) 'apply: writes logs/apply-bridge-update.log'
    Stop-Job $srv.Job -ErrorAction SilentlyContinue; Remove-Job $srv.Job -Force -ErrorAction SilentlyContinue

    $inst = New-Install 'apply-rollback'
    $srv = Start-HealthServer 503
    $r = Invoke-Supervisor @('--data-dir', $inst.Dir, '--stage-dir', $inst.Stage, '--bridge-port', "$($srv.Port)", '--bridge-pid', '999999',
      '--stop-hook', (Join-Path $inst.Dir 'stop-hook.sh'), '--restart-hook', (Join-Path $inst.Dir 'restart-hook.sh'), '--health-timeout', '2')
    $calls = ''
    if (Test-Path $inst.Calls) { $calls = [IO.File]::ReadAllText($inst.Calls) }
    Check ($r.Code -eq 1 -and $r.Err -match 'Rollback complete') 'rollback: unhealthy update exits 1 after rollback' "exit=$($r.Code) out=$($r.Out) err=$($r.Err)"
    Check ([IO.File]::ReadAllText((Join-Path $inst.Bin 'ham-bridge.exe')) -eq 'old ham-bridge.exe' -and (Test-Path (Join-Path $inst.Bin 'bridge-service.js'))) 'rollback: the previous bin is restored'
    Check ($calls -eq "stop 999999`nrestart `nstop 999999`nrestart `n") 'rollback: stops and restarts again' $calls
    Check ($r.Out -match 'Legacy caller \(interface 1, no --from-version\): update') 'rollback: legacy (interface 1) argv still runs the flow' $r.Out
    Check ((Test-Path (Join-Path $inst.Dir 'logs/update_rollback.log'))) 'rollback: writes logs/update_rollback.log'
    Stop-Job $srv.Job -ErrorAction SilentlyContinue; Remove-Job $srv.Job -Force -ErrorAction SilentlyContinue

    $inst = New-Install 'missing-binary'
    [IO.File]::WriteAllText((Join-Path $inst.Bin 'heimdall.exe'), 'old')
    $r = Invoke-Supervisor @('--data-dir', $inst.Dir, '--stage-dir', $inst.Stage, '--bridge-pid', '999999', '--stop-hook', (Join-Path $inst.Dir 'stop-hook.sh'), '--restart-hook', (Join-Path $inst.Dir 'restart-hook.sh'))
    Check ($r.Code -eq 1 -and $r.Err -match 'Update bundle is missing installed binary: heimdall.exe' -and -not (Test-Path $inst.Calls)) 'a bundle missing an installed binary is refused before the stop' "exit=$($r.Code) $($r.Err)"
  } else {
    Write-Host 'skip - live process and apply-flow checks (they need PowerShell 7 off Windows; the Windows run is the install test)'
  }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$($script:checks - $script:failures)/$($script:checks) checks passed"
if ($script:failures -gt 0) { exit 1 }
exit 0
