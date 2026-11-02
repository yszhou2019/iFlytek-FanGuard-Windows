# FanGuard

Adaptive CPU limiter for misbehaving Windows processes.

[中文说明 / Chinese version → README_CN.md](README_CN.md)

---

## Why this exists

This project was written for one concrete, annoying situation: **the iFlytek
voice input method (讯飞输入法) on Windows**. The same product has three
different problems, and none of them can be fixed by the user because the
software is closed-source.

### Problem 1 — Long dictation keeps disconnecting

In "long voice" mode you keep talking and the IME streams text out. In practice
long sessions frequently abort with:

```
网络故障，请重新输入
```

Short sentences usually work, long ones often do not. This is not a network
problem on the user's side — packet captures showed the TCP connection is
healthy (connect ~0.2 s, TLS ~0.1 s, ~417 KB/s upload, zero retransmits, no
proxy involved). In every failed session **the local client sends the first
FIN**, i.e. the iFlytek client or its account/session layer gives up mid-stream.
Reinstalling, restarting, changing DNS, disabling the firewall and raising the
log level changed nothing. It is a vendor-side defect.

### Problem 2 — The offline model is not accurate enough

The obvious workaround is offline recognition, but the local model's accuracy is
noticeably worse than the online one, so it is not a usable replacement for
dictation.

### Problem 3 — The way that *does* work burns a whole CPU core

What actually works is: dictate on the **phone**, and let the phone's
cross-screen input feature (跨屏输入) push the resulting text to Windows. The PC
is then only a *receiver*.

The Windows-side process behind that feature is:

```
C:\install\iFlytek\iFlyIME\3.0.1750\iFlyIMEConnector.exe     (32-bit)
```

Task Manager shows it as **跨屏输入(32bit)**. And it sits at **~100 % of one
core, permanently** — while:

* network IO is **0 bytes/sec**,
* disk IO is ~0,
* and it is doing no useful work at all.

That last point is the key observation. All the expensive work (acoustic model,
language model, decoding) happens **on the phone or in the cloud**. The Windows
process only receives finished text and forwards it. A process that receives a
few bytes of text has no reason to occupy 100 % of a core — so the CPU it burns
is **pure waste**, almost certainly a busy-wait / spin loop bug in closed-source
code we cannot patch.

The practical consequence is noise: on a laptop the fan spins up and never
stops, even when you are not dictating anything.

### What we can actually do about it

We cannot fix the vendor's code, and we do not want to replace the input method
with a home-grown one. But we *can* control how much CPU the operating system
lets that process have. Since the process is provably idle-spinning, taking CPU
away from it costs nothing.

That is all FanGuard is: an external, non-invasive CPU cap.

---

## What FanGuard does

FanGuard caps the CPU usage a process shows in **Task Manager** by periodically
suspending and resuming it. You set the limit as a plain number:

```json
"targetCpuPercent": 5
```

A closed-loop controller measures the real CPU usage and continuously adjusts
the run/pause ratio until the measured value matches the target.

* If the process is idle on its own, FanGuard backs off and leaves it alone.
* If the process restarts, FanGuard re-attaches automatically.
* Nothing is injected, patched, hooked or modified — it all works from outside,
  via `NtSuspendProcess` / `NtResumeProcess`.
* It is generic: point `processName` at any spinning process, not just iFlytek's.

## Requirements

* Windows 10 1809+ or Windows 11
* Administrator rights (the script elevates itself; with the default UAC setting
  for an administrator account no prompt is shown)

## Usage

```powershell
# 1. edit FanGuard.config.json and set your target, then:
.\FanGuard.ps1 install      # register a logon task and start guarding

.\FanGuard.ps1 status       # show task state, guard state, measured CPU
.\FanGuard.ps1 test         # run 20s, print the measured CPU, then exit
.\FanGuard.ps1 uninstall    # remove the task and restore full speed
```

If you prefer double-clicking, use the two one-purpose launchers:

```
install.cmd      # register the logon task and start guarding
uninstall.cmd    # remove the task and restore full speed
```

Both acquire administrator rights by themselves. Run `uninstall.cmd` before you
delete or move this folder, otherwise the task keeps pointing at a path that no
longer exists.

`FanGuard.cmd` is the general-purpose launcher for every other command:

```
FanGuard.cmd status
```

After `install`, everything is automatic: the guard starts at every logon and
re-attaches whenever the target process restarts.

## Configuration

`FanGuard.config.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `processName` | `iFlyIMEConnector` | Process to throttle (no `.exe`) |
| `targetCpuPercent` | `5` | CPU cap as shown in Task Manager |
| `periodMs` | `400` | Length of one run + pause cycle |
| `minRunMs` / `maxRunMs` | `5` / `380` | Controller limits for the run slice |
| `initialRunMs` | `40` | Starting run slice before the first measurement |
| `controlWindowSec` | `3` | How often the controller re-tunes |
| `deadbandPercent` | `1.0` | Ignore deviations smaller than this |
| `useEfficiencyMode` | `true` | Also apply Windows 11 EcoQoS (helps on 12th-gen+ CPUs) |
| `highResTimer` | `true` | Request 1 ms timer resolution for accurate sleeps |
| `taskName` | `FanGuard` | Name of the scheduled task |
| `logFile` | `FanGuard.log` | Log path (relative to the script) |
| `maxLogSizeKb` | `256` | Log rotation threshold |

Run `.\FanGuard.ps1 install` again after changing the config.

## How it works

```
loop every controlWindowSec:
    measure real CPU%  = (cpu_now - cpu_prev) / elapsed * 100
    runMs <- clamp(runMs * target / measured)
    every periodMs:  resume -> sleep runMs -> suspend -> sleep (periodMs - runMs)
```

Because the measurement spans the normal run/pause cycling, the number it
converges on is exactly the number Task Manager displays.

Measured on an i5-9300H with `iFlyIMEConnector.exe`:

| | CPU |
| --- | --- |
| unthrottled | 101.5 % |
| target 5 % | 4.6 – 5.6 % |

## Notes

* Efficiency Mode (EcoQoS) alone does **not** help on CPUs without efficiency
  cores (Intel 9th gen and older): it relies on moving threads to E-cores.
  FanGuard still enables it when possible, but the duty-cycle is what works
  everywhere.
* Very low targets (1–3 %) increase input latency slightly. Raise
  `targetCpuPercent` to 15–20 if a device feels laggy.
* Because of Windows timer granularity the reachable floor is roughly 3–4 %;
  a target of 1–2 % is not reliably achievable.

## License

MIT
