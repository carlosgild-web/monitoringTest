# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Windows process-monitoring solution consisting of a declarative JSON config, a PowerShell monitoring engine, a Python web dashboard, a settings editor, and bat-file launchers. The config (`monitoring_settings.json`) is the source of truth; every other component reads from it.

## How to run things

| Task | Command |
|---|---|
| Start all monitors + open console | `start_monitoring.bat` |
| Stop all monitors + close console | `stop_monitoring.bat` |
| Open the settings editor | `start_editor.bat` → browser at `http://localhost:5757` |
| Run the process monitor manually | `powershell -ExecutionPolicy Bypass -File scripts\process_monitor.ps1` |
| Run the web console manually | `python MonitoringConsole\monitoring_console.py` → browser at `http://localhost:5758` |

`start_monitoring.bat` uses two subroutines: `:LaunchScript` for PowerShell monitors and `:LaunchPython` for the console. Both skip a process that is already running (detected by command-line matching). To add a new monitor, add a `call :LaunchScript` line and uncomment its corresponding block.

## Architecture

### Data flow

```
monitoring_settings.json  ←→  server.py (port 5757)  ←→  monitoring_editor.html
        │
        └── scripts/process_monitor.ps1
                  │ writes on every state change
                  ▼
            logs/process_state.json
                  │
                  └── MonitoringConsole/monitoring_console.py (port 5758)
                            reads both files; live-checks via tasklist as fallback
```

### Component roles

**`scripts/process_monitor.ps1`** — the monitoring engine. Runs as a background PowerShell process. On each check cycle it detects running→down and down→running transitions, fires configured actions (`popup`, `log_to_file`, `email_draft`, `run_script`), and writes `logs/process_state.json`. Popup and email actions are suppressed on repeat alerts (spam guard); only `log_to_file` and `run_script` continue firing.

**`logs/process_state.json`** — shared live state written by the monitor, read by the console. Considered fresh if its `updated` timestamp is within `2 × max_check_interval + 15` seconds. Format: `{ updated, monitor_pid, processes: [{ name, display_name, required, is_running, last_check, down_since, alert_count }] }`.

**`MonitoringConsole/monitoring_console.py`** — the active web console. A single-file Python HTTP server (port 5758) that serves an embedded HTML/JS dashboard. It merges the state file with a live `tasklist` check on every request. The "Click here for instructions" button in the dashboard opens a modal populated from the process's `instructions` field. Auto-refreshes every 10 seconds.

**`MonitoringConsole/monitoring_console.ps1`** — a legacy WinForms PowerShell console. Still present but superseded by the Python web console. `start_monitoring.bat` now launches the Python version.

**`monitoring_editor.html` + `server.py`** — the settings editor. `server.py` (port 5757) serves the HTML and exposes `GET/POST /api/settings`. The editor works without the server (read-only, export-only mode) but requires it for saving. The editor renders each section lazily; the Processes panel starts collapsed.

**`scripts/show_status.ps1`** — a WinForms status dashboard showing monitor script states and config overview. Launched separately; not part of the default startup flow anymore.

## Configuration schema

Always bump `_meta.version` and update `_meta.last_updated` when modifying `monitoring_settings.json`.

### Field-name split: `instructions` vs `message_template`

**Processes** `on_not_running` actions use `instructions` (not `message_template`). This is what appears in the console's "Click here for instructions" modal.

**All other sections** (CPU, memory, disk, network) use `message_template` in `popup` and `log_to_file` actions.

The editor enforces this automatically: `actionFields()` switches label and field name based on the `sec` parameter passed from `renderAction()`.

### Threshold levels

`warning` → use `popup` and `log_to_file` only.  
`critical` → may additionally use `email_draft` and `run_script`.

CPU/memory thresholds require `percent` + `sustain_sec`. Disk uses `percent_used`. Network uses `latency_ms` or `condition: "unreachable"`.

### Template variables

`{timestamp}`, `{hostname}` — all sections  
`{current_value}`, `{percent}`, `{sustain_sec}` — CPU/memory  
`{current_value}`, `{percent_used}`, `{free_gb}` — disk  
`{host}`, `{port}`, `{current_value}`, `{latency_ms}` — network  
`{global.email_recipient}`, `{global.scripts_dir}` — resolved at runtime from `global`

### Adding a new monitor type

1. Add the script as `scripts/monitor_<type>.ps1` (mirror `process_monitor.ps1` structure).
2. Uncomment its `call :LaunchScript` line in `start_monitoring.bat`.
3. Add the script name (without extension) to `$MONITOR_SCRIPTS` in `scripts/stop_monitoring.ps1`.
4. Update `$SCRIPTS` in `scripts/show_status.ps1` to include the new key → filename mapping.

## PowerShell coding rules

**No non-ASCII characters in string literals.** PowerShell 5.1 reads `.ps1` files as Windows-1252 by default, so UTF-8 multi-byte characters in quoted strings corrupt at parse time. Use `[char]0xXXXX` for all Unicode symbols (e.g., `"$([char]0x25CF) RUNNING"`). Non-ASCII in comments is safe.

**No `Set-StrictMode -Version Latest`.** It causes terminating errors on null or missing property access, which kills the monitoring loop. Use `$ErrorActionPreference = 'Continue'` and wrap per-item checks in `try/catch`.

**Use `powershell.exe` explicitly** (not `powershell`) when spawning child processes for popups, to avoid ambiguity on systems with PowerShell 7.
