<#
.SYNOPSIS
    FanGuard - adaptive CPU limiter for a misbehaving Windows process.

.DESCRIPTION
    Some Windows processes busy-wait: they pin a whole CPU core while doing
    nothing useful (0 bytes/sec network IO). FanGuard caps the CPU usage such a
    process shows in Task Manager, by periodically suspending and resuming it.

    The limit is expressed directly as "CPU percent shown in Task Manager",
    e.g. targetCpuPercent = 5  ->  the process is held at about 5%.

    A closed-loop controller measures the real CPU usage and continuously
    adjusts the run/pause ratio, so the target is met even if the process
    changes its behaviour. If the process is idle on its own, FanGuard backs
    off and leaves it alone.

    Everything is done from outside the target process: no source code, no
    injection, no driver. It only needs to run elevated once.

.COMMANDS
    install     register a logon-triggered scheduled task and start the guard
    uninstall   remove the task and restore the process to full speed
    status      show task state, guard state, and measured CPU usage
    run         daemon mode (used by the scheduled task; do not call directly)
    test        run for a few seconds, print the measured CPU, then exit

.PARAMETER Command
    install | uninstall | status | run | test   (default: status)

.PARAMETER ConfigPath
    Path to the JSON config file. Defaults to FanGuard.config.json next to this
    script.

.PARAMETER Seconds
    Duration for the "test" command. Default 20.

.EXAMPLE
    .\FanGuard.ps1 install
    .\FanGuard.ps1 status
    .\FanGuard.ps1 test -Seconds 20
    .\FanGuard.ps1 uninstall

.NOTES
    Requires Windows 10 1809+ / Windows 11. Elevation is automatic.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status', 'run', 'test')]
    [string]$Command = 'status',

    [string]$ConfigPath,

    [int]$Seconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Paths and defaults
# ---------------------------------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptDir 'FanGuard.config.json'
}
$script:ResultFile = Join-Path $ScriptDir 'FanGuard.result.txt'

$DEFAULT_CONFIG = @{
    processName       = 'iFlyIMEConnector'
    targetCpuPercent  = 5
    periodMs          = 400      # one run + pause cycle
    minRunMs          = 5
    maxRunMs          = 380
    initialRunMs      = 40
    controlWindowSec  = 3        # how often the controller re-tunes
    deadbandPercent   = 1.0      # ignore small deviations
    useEfficiencyMode = $true    # also apply Win11 EcoQoS (harmless on old CPUs)
    highResTimer      = $true    # 1 ms timer resolution for accurate sleeps
    taskName          = 'FanGuard'
    logFile           = 'FanGuard.log'
    maxLogSizeKb      = 256
}

# ---------------------------------------------------------------------------
#  Native calls
# ---------------------------------------------------------------------------

$NATIVE = @'
using System;
using System.Runtime.InteropServices;

public class FG {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr h);

    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr h);

    [DllImport("winmm.dll")]
    public static extern int timeBeginPeriod(uint ms);

    [DllImport("winmm.dll")]
    public static extern int timeEndPeriod(uint ms);

    [StructLayout(LayoutKind.Sequential)]
    public struct PTS { public uint Version; public uint ControlMask; public uint StateMask; }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessInformation(IntPtr h, int cls, ref PTS info, uint size);

    public const uint ACCESS_SUSPEND = 0x0800;                 // PROCESS_SUSPEND_RESUME
    public const uint ACCESS_SETINFO = 0x0200;                 // PROCESS_SET_INFORMATION
    public const uint ACCESS_QUERYINFO = 0x0400;               // PROCESS_QUERY_INFORMATION

    public static string Eco(int pid, bool enable) {
        IntPtr h = OpenProcess(ACCESS_SETINFO | ACCESS_QUERYINFO, false, pid);
        if (h == IntPtr.Zero) return "eco: OpenProcess denied (" + Marshal.GetLastWin32Error() + ")";
        try {
            PTS s = new PTS();
            s.Version = 1; s.ControlMask = 1; s.StateMask = enable ? 1u : 0u;
            if (!SetProcessInformation(h, 4, ref s, (uint)Marshal.SizeOf(s)))
                return "eco: SetProcessInformation failed (" + Marshal.GetLastWin32Error() + ")";
            return enable ? "eco enabled" : "eco removed";
        } finally { CloseHandle(h); }
    }
}
'@

if (-not ('FG' -as [type])) { Add-Type -TypeDefinition $NATIVE -ErrorAction Stop }

# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        $DEFAULT_CONFIG | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding ASCII
    }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($k in $DEFAULT_CONFIG.Keys) {
        if (-not ($cfg.PSObject.Properties.Name -contains $k)) {
            $cfg | Add-Member -MemberType NoteProperty -Name $k -Value $DEFAULT_CONFIG[$k] -Force
        }
    }
    return $cfg
}

function Resolve-LogPath([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return Join-Path $ScriptDir $p
}

function Write-Log {
    param([string]$Message, [switch]$NoFile)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message

    # always mirrored to the result file, so the non-elevated caller can show it
    try { Add-Content -Path $script:ResultFile -Value $line -Encoding ASCII } catch { }

    if (-not $NoFile) {
        try {
            $lf = Resolve-LogPath $script:LogFile
            if (Test-Path $lf) {
                if ((Get-Item $lf).Length -gt ($script:MaxLogKb * 1024)) { Remove-Item $lf -Force }
            }
            Add-Content -Path $lf -Value $line -Encoding ASCII
        } catch { }
    }
    Write-Output $line
}

# ---------------------------------------------------------------------------
#  Elevation: relaunch self with -Verb RunAs
# ---------------------------------------------------------------------------

if (-not (Test-IsAdmin)) {
    $psiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-Command', $Command, '-Seconds', "$Seconds")
    if ($ConfigPath) { $psiArgs += @('-ConfigPath', "`"$ConfigPath`"") }

    if ($Command -eq 'run') {
        # daemon launched by the scheduled task: fire and forget
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $psiArgs | Out-Null
        exit 0
    }

    # everything else: wait for the elevated copy, then show what it wrote
    Remove-Item $script:ResultFile -ErrorAction SilentlyContinue
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList $psiArgs
    if (Test-Path $script:ResultFile) { Get-Content $script:ResultFile }
    exit 0
}

# ---------------------------------------------------------------------------
#  Config (loaded after elevation so relative paths resolve the same way)
# ---------------------------------------------------------------------------

$cfg = Get-Config
$script:LogFile  = $cfg.logFile
$script:MaxLogKb = [int]$cfg.maxLogSizeKb
$ProcName   = $cfg.processName
$Target     = [double]$cfg.targetCpuPercent
$PeriodMs   = [int]$cfg.periodMs
$MinRun     = [int]$cfg.minRunMs
$MaxRun     = [int]$cfg.maxRunMs
$CtrlSec    = [int]$cfg.controlWindowSec
$Deadband   = [double]$cfg.deadbandPercent
$TaskName   = $cfg.taskName

if ($MaxRun -gt ($PeriodMs - $MinRun)) { $MaxRun = $PeriodMs - $MinRun }

# ---------------------------------------------------------------------------
#  Target process management
# ---------------------------------------------------------------------------

$handles = @{}

function Sync-Targets {
    $procs = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue)

    foreach ($p in $procs) {
        if (-not $handles.ContainsKey($p.Id)) {
            $h = [FG]::OpenProcess([FG]::ACCESS_SUSPEND, $false, $p.Id)
            if ($h -eq [IntPtr]::Zero) {
                Write-Log ("PID {0}: OpenProcess denied (Win32 {1}); skipped" -f $p.Id,
                           [Runtime.InteropServices.Marshal]::GetLastWin32Error())
                continue
            }
            $handles[$p.Id] = $h
            $msg = "PID {0}: attached" -f $p.Id
            if ($cfg.useEfficiencyMode) { $msg += '; ' + [FG]::Eco($p.Id, $true) }
            Write-Log $msg
        }
    }

    $alive = @($procs | ForEach-Object { $_.Id })
    foreach ($k in @($handles.Keys)) {
        if ($alive -notcontains $k) {
            [void][FG]::NtResumeProcess($handles[$k])
            [FG]::CloseHandle($handles[$k]) | Out-Null
            $handles.Remove($k)
            Write-Log ("PID {0}: exited, handle released" -f $k)
        }
    }
}

function Release-Targets {
    foreach ($k in @($handles.Keys)) {
        [void][FG]::NtResumeProcess($handles[$k])
        [FG]::CloseHandle($handles[$k]) | Out-Null
    }
    $handles.Clear()
    foreach ($p in @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue)) {
        [void][FG]::Eco($p.Id, $false)
        Write-Log ("PID {0}: released, eco removed" -f $p.Id)
    }
}

function Measure-TargetCpu {
    # Average CPU% over a wall-clock window. Valid while the guard is cycling;
    # inside the guard loop we use snapshot deltas instead (see Start-Guard).
    param([int]$WindowSec)
    $t0 = Get-Date
    $before = Get-CpuSum
    Start-Sleep -Seconds $WindowSec
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    if ($before -lt 0) { return -1 }
    $now = Get-CpuSum
    if ($now -lt 0) { return -1 }
    return [math]::Round(($now - $before) / $elapsed * 100, 2)
}

function Get-CpuSum {
    # Total CPU seconds consumed so far by every instance of the target process.
    # Returns -1 when the process is not running.
    $procs = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return -1 }
    $sum = 0.0
    foreach ($p in $procs) { $sum += $p.CPU }
    return $sum
}

# ---------------------------------------------------------------------------
#  The closed-loop daemon
# ---------------------------------------------------------------------------

function Start-Guard {
    param([int]$RunForSec = 0)   # 0 = forever

    # single instance: if another guard is already running, step aside
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($false, "Global\FanGuard_$ProcName", [ref]$created)
    if (-not $created) {
        Write-Log "another guard instance is already running; exiting"
        return
    }

    Sync-Targets
    if ($handles.Count -eq 0) {
        Write-Log ("[{0}] is not running - nothing to throttle" -f $ProcName)
        if ($RunForSec -gt 0) { return }
    }

    if ($cfg.highResTimer) { [void][FG]::timeBeginPeriod(1) }

    $runMs  = [int]$cfg.initialRunMs
    $lastTune = Get-Date
    $lastCpu = Get-CpuSum
    $baseline = -1

    Write-Log ("Guard up. target={0}%  period={1}ms  run={2}ms  (adaptive)" -f $Target, $PeriodMs, $runMs)

    $deadline = if ($RunForSec -gt 0) { (Get-Date).AddSeconds($RunForSec) } else { $null }
    $cycles = 0

    try {
        while ($true) {
            if ($deadline -and (Get-Date) -ge $deadline) { break }

            # ---- one duty cycle ----
            foreach ($k in @($handles.Keys)) { [void][FG]::NtResumeProcess($handles[$k]) }
            Start-Sleep -Milliseconds $runMs
            foreach ($k in @($handles.Keys)) { [void][FG]::NtSuspendProcess($handles[$k]) }
            Start-Sleep -Milliseconds ($PeriodMs - $runMs)
            $cycles++

            # ---- re-attach if the process restarted ----
            if ($cycles % 5 -eq 0) { Sync-Targets }

            # ---- closed-loop tuning ----
            # The measurement must span the normal run/pause cycling, so we take
            # CPU snapshots at tune points and never sleep in between.
            if (((Get-Date) - $lastTune).TotalSeconds -ge $CtrlSec) {
                $nowCpu = Get-CpuSum
                $elapsed = ((Get-Date) - $lastTune).TotalSeconds
                if ($nowCpu -ge 0 -and $lastCpu -ge 0 -and $elapsed -gt 0) {
                    $m = [math]::Round(($nowCpu - $lastCpu) / $elapsed * 100, 2)
                    if ($baseline -lt 0) {
                        $baseline = $m
                        Write-Log ("first sample: {0} %" -f $m)
                    }
                    if ([math]::Abs($m - $Target) -gt $Deadband) {
                        if ($m -gt 0.05) {
                            $desired = $runMs * ($Target / $m)
                        } else {
                            $desired = $MaxRun
                        }
                        $desired = [math]::Round($runMs + 0.6 * ($desired - $runMs))
                        $desired = [math]::Min([double]$MaxRun, [math]::Max([double]$MinRun, $desired))
                        $runMs = [int]$desired
                    }
                    Write-Log ("measured {0,6} %  target {1} %  -> run {2} ms / {3} ms" -f $m, $Target, $runMs, $PeriodMs)
                }
                $lastTune = Get-Date
                $lastCpu  = Get-CpuSum
            }
        }
    }
    finally {
        Release-Targets
        if ($cfg.highResTimer) { [void][FG]::timeEndPeriod(1) }
    }

    if ($RunForSec -gt 0) {
        Write-Log ("test finished after {0} cycles; process released" -f $cycles)
        $after = Measure-TargetCpu -WindowSec 4
        Write-Log ("unthrottled again: {0} %  (this is what it would be without FanGuard)" -f $after)
    }
}

# ---------------------------------------------------------------------------
#  Commands
# ---------------------------------------------------------------------------

function Get-TaskArgsLine {
    return '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Command run -ConfigPath "{1}"' -f `
        $PSCommandPath, $ConfigPath
}

function Stop-GuardDaemons {
    # Kill running guard daemons only. Never match this own process: the
    # installer/uninstaller itself carries the script name in its command line.
    $me = $PID
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $me -and $_.CommandLine -and
            ($_.CommandLine -match '-Command run' -or $_.CommandLine -match 'fan_guard|eco_mode|cpu_throttle')
        } |
        ForEach-Object {
            Write-Log ("stopping guard PID {0}" -f $_.ProcessId)
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

try {

switch ($Command) {

    'install' {
        # stop whatever guard is running now
        Stop-GuardDaemons
        Start-Sleep -Seconds 1
        Release-Targets

        Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-TaskArgsLine)
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Administrators' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                        -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description ("Adaptive CPU cap for {0} (target {1}%)" -f $ProcName, $Target) -Force | Out-Null

        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 4
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Log ("installed task '{0}' state={1} target={2}%" -f $TaskName, $t.State, $Target)
        Write-Log 'Automatic from now on: starts at every logon, re-attaches if the process restarts.'
        Write-Log 'Change the limit by editing FanGuard.config.json, then run: .\FanGuard.ps1 install'
    }

    'uninstall' {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Stop-GuardDaemons
        Start-Sleep -Seconds 1
        Release-Targets
        Write-Log "uninstalled task '$TaskName'; process restored to full speed"
    }

    'status' {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t) { Write-Log ("task    : {0}  state={1}" -f $TaskName, $t.State) }
        else    { Write-Log ("task    : {0}  NOT installed" -f $TaskName) -NoFile }

        $guards = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -match '-Command run' })
        if ($guards.Count -gt 0) { Write-Log ("guard   : running ({0} daemon(s))" -f $guards.Count) -NoFile }
        else                     { Write-Log 'guard   : NOT running' -NoFile }

        $m = Measure-TargetCpu -WindowSec 3
        if ($m -lt 0) { Write-Log ("process : {0} not running" -f $ProcName) -NoFile }
        else {
            Write-Log ("process : {0}  CPU = {1} %   (target {2} %)" -f $ProcName, $m, $Target) -NoFile
        }
        Write-Log ("config  : {0}" -f $ConfigPath) -NoFile
    }

    'test'  { Start-Guard -RunForSec $Seconds }

    'run'   { Start-Guard }
}

}
catch {
    Write-Log ("ERROR: " + $_.Exception.Message)
    Write-Log ("at: " + $_.InvocationInfo.PositionMessage)
    exit 1
}
