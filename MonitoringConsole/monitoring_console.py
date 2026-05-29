#!/usr/bin/env python3
"""
Web-based Process Monitoring Console.
Usage: python monitoring_console.py
       Browser opens automatically at http://localhost:5758
"""
import json
import subprocess
import webbrowser
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

BASE           = Path(__file__).parent.parent.resolve()
SETTINGS_FILE  = BASE / "monitoring_settings.json"
STATE_FILE     = BASE / "logs" / "process_state.json"
PERF_STATE_FILE = BASE / "logs" / "performance_state.json"
DISK_STATE_FILE = BASE / "logs" / "disk_state.json"
NET_STATE_FILE  = BASE / "logs" / "network_state.json"
PORT          = 5758


def _parse_dt(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def _check_fresh(path, max_interval_sec):
    """Return True if the state file exists and was updated within the expected window."""
    try:
        d = json.loads(path.read_text(encoding="utf-8-sig"))
        dt = _parse_dt(d.get("updated", ""))
        if dt:
            return int((datetime.now() - dt).total_seconds()) < max_interval_sec * 2 + 20
    except Exception:
        pass
    return False


def check_running(exe_name: str):
    """Live check: is exe_name currently running? Returns True/False, or None on error."""
    try:
        r = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {exe_name}", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, timeout=5,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return exe_name.lower() in r.stdout.lower()
    except Exception:
        return None


def get_status():
    cfg, state = {}, {}
    try:
        cfg   = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception:
        pass
    try:
        state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        pass

    updated_str  = state.get("updated", "")
    updated_dt   = _parse_dt(updated_str)
    age_sec      = int((datetime.now() - updated_dt).total_seconds()) if updated_dt else None
    max_interval = max((p.get("check_interval_sec", 30) for p in cfg.get("processes", [])), default=30)
    proc_ok      = age_sec is not None and age_sec < (max_interval * 2 + 15)

    perf_int = cfg.get("performance", {}).get("cpu", {}).get("check_interval_sec", 10)
    disk_int = min((d.get("check_interval_sec", 60) for d in cfg.get("disk", [])), default=60)
    net_int  = min((h.get("check_interval_sec", 30) for h in cfg.get("network", [])), default=30)
    monitors = {
        "process":     proc_ok,
        "performance": _check_fresh(PERF_STATE_FILE, perf_int),
        "disk":        _check_fresh(DISK_STATE_FILE,  disk_int),
        "network":     _check_fresh(NET_STATE_FILE,   net_int),
    }

    state_map = {p["name"]: p for p in state.get("processes", [])}
    processes = []
    for pc in cfg.get("processes", []):
        nm  = pc.get("name", "")
        sp  = state_map.get(nm, {})
        on_not_running = pc.get("actions", {}).get("on_not_running", [])
        actions     = [a.get("type", "") for a in on_not_running]
        instructions = next((a["instructions"] for a in on_not_running if a.get("instructions")), "")
        live        = check_running(nm)
        is_running  = live if live is not None else sp.get("is_running")
        down_since  = sp.get("down_since")
        down_sec    = None
        if is_running is False and down_since:
            ds = _parse_dt(down_since)
            if ds:
                down_sec = int((datetime.now() - ds).total_seconds())
        processes.append({
            "name":         nm,
            "display_name": pc.get("display_name", nm),
            "required":     pc.get("required", False),
            "check_sec":    pc.get("check_interval_sec", 30),
            "is_running":   is_running,
            "down_since":   down_since,
            "down_sec":     down_sec,
            "last_check":   sp.get("last_check"),
            "alert_count":  sp.get("alert_count", 0),
            "actions":      actions,
            "instructions": instructions,
        })

    running_count = sum(1 for p in processes if p["is_running"] is True)

    perf_state = {}
    try:
        perf_state = json.loads(PERF_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    disk_state = {}
    try:
        disk_state = json.loads(DISK_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    net_state = {}
    try:
        net_state = json.loads(NET_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    return {
        "engine":        {"ok": any(monitors.values()), "monitors": monitors,
                          "updated": updated_str, "age_sec": age_sec,
                          "pid": state.get("monitor_pid")},
        "processes":     processes,
        "total":         len(processes),
        "running_count": running_count,
        "performance":   perf_state.get("metrics", []),
        "disks":         disk_state.get("drives", []),
        "network":       net_state.get("hosts", []),
        "server_time":   datetime.now().strftime("%H:%M:%S"),
        "version":       cfg.get("_meta", {}).get("version", "?"),
    }


HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Monitoring Console</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#f0f4f9;--bg2:#ffffff;--bg3:#e8edf7;--card:#ffffff;
  --border:#d0d9eb;--text:#1a2740;--muted:#5e7191;
  --green:#15803d;--green-bg:#f0fdf4;--green-bd:#86efac;
  --red:#b91c1c;--red-bg:#fef2f2;--red-bd:#fca5a5;
  --orange:#c2410c;--orange-bg:#fff7ed;--orange-bd:#fed7aa;
  --accent:#2563eb;
}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;height:100vh;display:flex;flex-direction:column;overflow:hidden}

/* ── TOP BAR ── */
.topbar{background:var(--bg2);border-bottom:1px solid var(--border);padding:0 18px;height:46px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.topbar-left{display:flex;align-items:center;gap:9px}
.app-icon{width:26px;height:26px;background:linear-gradient(135deg,#2563eb,#0891b2);border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:13px;flex-shrink:0}
.app-title{font-size:14px;font-weight:700;color:var(--text)}
.version-badge{background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:2px 8px;font-size:10px;color:var(--muted)}
.topbar-right{display:flex;align-items:center;gap:8px;font-size:11px;color:var(--muted)}
.pulse-dot{width:6px;height:6px;border-radius:50%;background:var(--green);animation:pulse 2.5s ease-in-out infinite;flex-shrink:0}
.pulse-dot.off{background:var(--muted);animation:none}

/* ── STATUS BAR ── */
.status-bar{background:var(--bg2);border-bottom:1px solid var(--border);padding:0 18px;height:38px;display:flex;align-items:center;gap:14px;flex-shrink:0;font-size:13px}
.bar-sep{width:1px;height:16px;background:var(--border)}
.clr-green{color:var(--green)}.clr-red{color:var(--red)}.clr-muted{color:var(--muted)}
.stat-pill{display:flex;align-items:center;gap:4px}
.stat-num{font-weight:700;font-size:14px}
.mon-item{display:flex;align-items:center;gap:5px;font-size:12px;font-weight:600;color:var(--muted);white-space:nowrap}
.mon-dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;background:#94a3b8}
.mon-active .mon-dot{background:var(--green)}
.mon-active{color:var(--green)}

/* ── ALERT BANNER ── */
.alert-banner{background:#fff8e1;border-bottom:2px solid #f59e0b;padding:7px 18px;display:none;align-items:center;gap:8px;flex-shrink:0;font-size:12px;color:#92400e;font-weight:500}
.alert-banner.visible{display:flex}
.alert-icon{font-size:15px;flex-shrink:0}
.alert-name{font-weight:700;color:#78350f}
.alert-link{font-family:monospace;background:#fef3c7;border:1px solid #f59e0b;border-radius:4px;padding:1px 6px;font-size:11px;color:#92400e}

/* ── MAIN GRID ── */
.main-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;padding:10px 14px;flex:1;min-height:0;overflow:hidden}
.col{display:flex;flex-direction:column;gap:8px;min-height:0;overflow:hidden}
.section{background:var(--card);border:1px solid var(--border);border-radius:9px;display:flex;flex-direction:column;min-height:0;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.06)}
.sec-head{padding:7px 13px 6px;border-bottom:1px solid var(--border);flex-shrink:0}
.sec-title{font-size:9px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:var(--muted)}
.sec-body{overflow:auto;flex:1}

/* ── ITEM ROW ── */
.item-row{display:flex;align-items:center;gap:9px;padding:6px 13px;border-bottom:1px solid var(--border);transition:background .12s;min-height:44px}
.item-row:last-child{border-bottom:none}
.item-row:hover{background:var(--bg)}
.item-accent{width:3px;height:26px;border-radius:2px;flex-shrink:0}
.acc-green{background:var(--green)}.acc-red{background:var(--red)}.acc-orange{background:var(--orange)}.acc-gray{background:#94a3b8}
.item-name{flex:1;min-width:0}
.item-label{font-weight:600;font-size:14px;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item-sub{font-size:12px;color:var(--muted);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item-metric{flex-shrink:0;text-align:right;min-width:78px}
.metric-val{font-size:16px;font-weight:700;color:var(--text)}
.metric-bar{height:5px;background:var(--bg3);border-radius:2px;overflow:hidden;margin-top:4px;width:78px}
.metric-fill{height:100%;border-radius:2px;transition:width .5s ease}
.fill-ok{background:var(--green)}.fill-warn{background:var(--orange)}.fill-crit{background:var(--red)}
.item-badge{flex-shrink:0;min-width:76px;text-align:right}
.badge{display:inline-block;padding:3px 9px;border-radius:20px;font-size:11px;font-weight:700;letter-spacing:.3px;white-space:nowrap}
.badge-green{background:var(--green-bg);color:var(--green);border:1px solid var(--green-bd)}
.badge-red{background:var(--red-bg);color:var(--red);border:1px solid var(--red-bd)}
.badge-orange{background:var(--orange-bg);color:var(--orange);border:1px solid var(--orange-bd)}
.badge-gray{background:var(--bg3);color:var(--muted);border:1px solid var(--border)}
.btn-warn{background:var(--red-bg);color:var(--red);border:1px solid var(--red-bd);border-radius:5px;padding:3px 8px;font-size:11px;font-weight:700;cursor:pointer;white-space:nowrap;margin-left:4px}
.btn-warn:hover{background:var(--red-bd)}
.empty-row{padding:18px 13px;text-align:center;color:var(--muted);font-size:12px}
/* ── SECTION COLORS ── */
.sec-head{background:var(--bg3)}
.sec-processes .sec-head{background:#EFF6FF;border-bottom-color:#BFDBFE}.sec-processes .sec-title{color:#1E40AF}.sec-processes .sec-body{background:#FAFCFF}
.sec-perf .sec-head{background:#F5F3FF;border-bottom-color:#C4B5FD}.sec-perf .sec-title{color:#5B21B6}.sec-perf .sec-body{background:#FDFBFF}
.sec-disk .sec-head{background:#ECFDF5;border-bottom-color:#A7F3D0}.sec-disk .sec-title{color:#065F46}.sec-disk .sec-body{background:#FAFFFE}
.sec-net .sec-head{background:#FFF7ED;border-bottom-color:#FED7AA}.sec-net .sec-title{color:#9A3412}.sec-net .sec-body{background:#FFFDF8}

/* ── FOOTER ── */
.footer{background:var(--bg2);border-top:1px solid var(--border);height:32px;padding:0 18px;display:flex;align-items:center;justify-content:space-between;font-size:11px;color:var(--muted);flex-shrink:0}
.cdbar-wrap{display:flex;align-items:center;gap:6px}
.cdbar{width:56px;height:3px;background:var(--border);border-radius:2px;overflow:hidden}
.cdbar-fill{height:100%;background:var(--accent);border-radius:2px;transition:width 1s linear}

/* ── MODAL ── */
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.35);display:none;align-items:center;justify-content:center;z-index:200;backdrop-filter:blur(3px)}
.overlay.open{display:flex}
.modal{background:var(--bg2);border:1px solid var(--border);border-radius:11px;padding:22px 24px;max-width:420px;width:calc(100% - 32px);box-shadow:0 12px 40px rgba(0,0,0,.14);animation:slideUp .2s ease}
.modal-title{font-size:15px;font-weight:700;color:var(--text);margin-bottom:3px}
.modal-sub{font-size:11px;color:var(--muted);margin-bottom:16px}
.mrow{margin-bottom:12px}
.mrow-label{font-size:9px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--muted);margin-bottom:4px}
.mrow-val{font-size:12px;color:var(--text)}.mrow-val.red{color:var(--red)}.mrow-val.orange{color:var(--orange)}
.chips{display:flex;gap:5px;flex-wrap:wrap}
.chip{background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:2px 10px;font-size:11px;color:var(--text)}
.modal-note{background:var(--orange-bg);border:1px solid var(--orange-bd);border-left:3px solid var(--orange);border-radius:7px;padding:10px 13px;font-size:12px;color:var(--text);line-height:1.6;margin-bottom:16px;white-space:pre-line}
.btn-close{width:100%;padding:9px;background:var(--bg3);border:1px solid var(--border);border-radius:7px;color:var(--text);font-size:13px;font-weight:600;cursor:pointer}
.btn-close:hover{background:var(--border)}

/* ── ANIMATIONS ── */
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
@keyframes slideUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.fade-in{animation:fadeIn .2s ease}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="app-icon">📊</div>
    <div class="app-title">Monitoring Console</div>
    <span class="version-badge" id="ver">v—</span>
  </div>
  <div class="topbar-right">
    <div class="pulse-dot" id="pdot"></div>
    <span id="refresh-lbl">Connecting…</span>
  </div>
</div>

<div class="status-bar">
  <div id="mon-process" class="mon-item"><span class="mon-dot"></span><span>Process</span></div>
  <div id="mon-perf" class="mon-item"><span class="mon-dot"></span><span>Performance</span></div>
  <div id="mon-disk" class="mon-item"><span class="mon-dot"></span><span>Disk</span></div>
  <div id="mon-net" class="mon-item"><span class="mon-dot"></span><span>Network</span></div>
  <div class="bar-sep"></div>
  <span class="clr-muted" style="font-size:12px" id="ehealth"></span>
</div>

<div class="alert-banner" id="alert-banner">
  <span class="alert-icon">⚠️</span>
  <span>Monitor scripts not running: <span class="alert-name" id="alert-names"></span></span>
  <span style="color:#b45309">—</span>
  <span>Run <span class="alert-link">start_monitoring.bat</span> to activate.</span>
</div>

<div class="main-grid">
  <div class="col">
    <div class="section sec-processes">
      <div class="sec-head"><span class="sec-title">Processes</span></div>
      <div class="sec-body" id="proc-list"><div class="empty-row">Loading…</div></div>
    </div>
    <div class="section sec-disk">
      <div class="sec-head"><span class="sec-title">Disk</span></div>
      <div class="sec-body" id="disk-list"><div class="empty-row">Loading…</div></div>
    </div>
  </div>
  <div class="col">
    <div class="section sec-perf">
      <div class="sec-head"><span class="sec-title">Performance</span></div>
      <div class="sec-body" id="perf-list"><div class="empty-row">Loading…</div></div>
    </div>
    <div class="section sec-net">
      <div class="sec-head"><span class="sec-title">Network</span></div>
      <div class="sec-body" id="net-list"><div class="empty-row">Loading…</div></div>
    </div>
  </div>
</div>

<div class="footer">
  <span id="footer-lbl">Last refresh: —</span>
  <div class="cdbar-wrap">
    Auto-refresh in <span id="cd-num">10</span>s
    <div class="cdbar"><div class="cdbar-fill" id="cd-fill" style="width:100%"></div></div>
  </div>
</div>

<div class="overlay" id="overlay" onclick="if(event.target===this)closeModal()">
  <div class="modal">
    <div class="modal-title" id="m-title">Process Not Running</div>
    <div class="modal-sub"   id="m-exe"></div>
    <div class="mrow">
      <div class="mrow-label">Current Status</div>
      <div class="mrow-val red">● NOT RUNNING</div>
    </div>
    <div class="mrow" id="m-down-row">
      <div class="mrow-label">Down Since</div>
      <div class="mrow-val orange" id="m-down">—</div>
    </div>
    <div class="mrow">
      <div class="mrow-label">Alerts Sent</div>
      <div class="mrow-val" id="m-alerts">0</div>
    </div>
    <div class="mrow" id="m-act-row">
      <div class="mrow-label">Configured Actions</div>
      <div class="chips" id="m-chips"></div>
    </div>
    <div class="modal-note" id="m-note"></div>
    <button class="btn-close" onclick="closeModal()">Close</button>
  </div>
</div>

<script>
const REFRESH = 10;
const ACT_ICONS = {popup:'🔔', log_to_file:'📝', email_draft:'📧', run_script:'⚙️'};
let cdTimer, cdVal = REFRESH;

function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function fmtDur(sec){
  if(sec==null||sec<0) return '—';
  const h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60),s=sec%60;
  if(h>0) return h+'h '+m+'m'; if(m>0) return m+'m '+s+'s'; return s+'s';
}
function lvlBadge(lvl){
  const l=(lvl||'ok').toLowerCase();
  if(l==='critical') return '<span class="badge badge-red">CRITICAL</span>';
  if(l==='warning')  return '<span class="badge badge-orange">WARNING</span>';
  if(l==='unknown')  return '<span class="badge badge-gray">UNKNOWN</span>';
  return '<span class="badge badge-green">OK</span>';
}
function accColor(lvl){
  const l=(lvl||'ok').toLowerCase();
  return l==='critical'?'acc-red':l==='warning'?'acc-orange':l==='unknown'?'acc-gray':'acc-green';
}

function render(d){
  document.getElementById('ver').textContent         = 'v'+d.version;
  document.getElementById('refresh-lbl').textContent = 'Refreshed '+d.server_time;
  document.getElementById('footer-lbl').textContent  = 'Last refresh: '+d.server_time;

  const eng=d.engine, eh=document.getElementById('ehealth'), pd=document.getElementById('pdot');
  const mons=eng.monitors||{};
  const monIds={process:'mon-process',performance:'mon-perf',disk:'mon-disk',network:'mon-net'};
  Object.entries(monIds).forEach(([k,id])=>{
    const el=document.getElementById(id);
    if(el) el.className='mon-item '+(mons[k]?'mon-active':'');
  });
  const anyActive=Object.values(mons).some(v=>v);
  pd.className=anyActive?'pulse-dot':'pulse-dot off';
  eh.textContent=anyActive?'Updated '+fmtDur(eng.age_sec)+' ago':'';

  const inactive=Object.entries(mons).filter(([,v])=>!v).map(([k])=>k.charAt(0).toUpperCase()+k.slice(1));
  const banner=document.getElementById('alert-banner');
  document.getElementById('alert-names').textContent=inactive.join(', ');
  banner.classList.toggle('visible', inactive.length>0);

  // processes
  const pl=document.getElementById('proc-list');
  if(!d.processes.length){ pl.innerHTML='<div class="empty-row">No processes configured.</div>'; }
  else { pl.innerHTML = d.processes.map(p => {
    const run=p.is_running===true, unk=p.is_running===null;
    const lvl=run?'ok':unk?'unknown':'critical';
    const sub=run?(p.last_check?'Last check: '+esc(p.last_check):''):
              p.down_since?'Down '+fmtDur(p.down_sec)+' &nbsp;·&nbsp; Alerts: '+p.alert_count:'Not detected';
    const btn=!run?`<button class="btn-warn" onclick='showModal(${JSON.stringify(p)})'>⚠ Info</button>`:'';
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-name"><div class="item-label">${esc(p.display_name)}</div><div class="item-sub">${esc(p.name)}&nbsp;·&nbsp;${p.required?'Required':'Optional'}&nbsp;·&nbsp;${sub}</div></div>
  <div class="item-badge">${run?'<span class="badge badge-green">RUNNING</span>':unk?'<span class="badge badge-gray">UNKNOWN</span>':'<span class="badge badge-red">NOT RUNNING</span>'}</div>
  ${btn}
</div>`;
  }).join(''); }

  // performance
  const pfl=document.getElementById('perf-list');
  if(!d.performance||!d.performance.length){ pfl.innerHTML='<div class="empty-row">Start performance_monitor.ps1</div>'; }
  else { pfl.innerHTML = d.performance.map(m => {
    const lvl=(m.current_level||'ok').toLowerCase();
    const val=m.current_value!=null?Math.round(m.current_value):null;
    const pct=m.current_value!=null?Math.min(100,Math.round(m.current_value)):0;
    const fc=lvl==='critical'?'fill-crit':lvl==='warning'?'fill-warn':'fill-ok';
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-name"><div class="item-label">${esc(m.display_name)}</div><div class="item-sub">Last check: ${esc(m.last_check||'—')}</div></div>
  <div class="item-metric"><div class="metric-val">${val!=null?val+'%':'—'}</div><div class="metric-bar"><div class="metric-fill ${fc}" style="width:${pct}%"></div></div></div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
  }).join(''); }

  // disk
  const dkl=document.getElementById('disk-list');
  if(!d.disks||!d.disks.length){ dkl.innerHTML='<div class="empty-row">Start monitor_disk.ps1</div>'; }
  else { dkl.innerHTML = d.disks.map(m => {
    const lvl=(m.current_level||'ok').toLowerCase();
    const val=m.percent_used!=null?Math.round(m.percent_used):null;
    const pct=m.percent_used!=null?Math.min(100,Math.round(m.percent_used)):0;
    const fc=lvl==='critical'?'fill-crit':lvl==='warning'?'fill-warn':'fill-ok';
    const sub=m.free_gb!=null?`${esc(m.drive)}&nbsp;·&nbsp;${m.free_gb} GB free`:`${esc(m.drive)}&nbsp;·&nbsp;Unavailable`;
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-name"><div class="item-label">${esc(m.display_name)}</div><div class="item-sub">${sub}</div></div>
  <div class="item-metric">${val!=null?`<div class="metric-val">${val}%</div><div class="metric-bar"><div class="metric-fill ${fc}" style="width:${pct}%"></div></div>`:'<div class="metric-val clr-muted">—</div>'}</div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
  }).join(''); }

  // network
  const ntl=document.getElementById('net-list');
  if(!d.network||!d.network.length){ ntl.innerHTML='<div class="empty-row">Start monitor_network.ps1</div>'; }
  else { ntl.innerHTML = d.network.map(m => {
    const lvl=(m.current_level||'ok').toLowerCase(), ok=m.reachable===true;
    const lat=(ok&&m.latency_ms!=null)?`${m.latency_ms} ms`:'';
    const sub=`${esc(m.host)}${m.port?':'+m.port:''}&nbsp;·&nbsp;${esc((m.protocol||'').toUpperCase())}${lat?'&nbsp;·&nbsp;'+lat:''}`;
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-name"><div class="item-label">${esc(m.name)}</div><div class="item-sub">${sub}</div></div>
  <div class="item-badge">${ok?'<span class="badge badge-green">ONLINE</span>':'<span class="badge badge-red">OFFLINE</span>'}</div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
  }).join(''); }
}

function showModal(p){
  document.getElementById('m-title').textContent  = p.display_name+' — Not Running';
  document.getElementById('m-exe').textContent    = p.name+(p.required?' · Required':' · Optional');
  document.getElementById('m-alerts').textContent = p.alert_count;
  const dr=document.getElementById('m-down-row');
  if(p.down_since){ dr.style.display=''; document.getElementById('m-down').textContent=p.down_since+(p.down_sec!=null?'  ('+fmtDur(p.down_sec)+')':''); }
  else { dr.style.display='none'; }
  const ar=document.getElementById('m-act-row'), chips=document.getElementById('m-chips');
  if(p.actions&&p.actions.length){ ar.style.display=''; chips.innerHTML=p.actions.map(a=>`<span class="chip">${ACT_ICONS[a]||'•'} ${esc(a)}</span>`).join(''); }
  else { ar.style.display='none'; }
  document.getElementById('m-note').textContent = p.instructions||
    (p.display_name+' ('+p.name+') is currently not running. '+(p.required?'This process is marked as Required. ':'')+'Start the process manually to stop alerts.');
  document.getElementById('overlay').classList.add('open');
}
function closeModal(){ document.getElementById('overlay').classList.remove('open'); }
document.addEventListener('keydown', e=>{ if(e.key==='Escape') closeModal(); });

async function fetchStatus(){
  try{
    const r=await fetch('/api/status');
    if(!r.ok) throw new Error('HTTP '+r.status);
    render(await r.json());
  } catch(e){ document.getElementById('etxt').textContent='Error: '+e.message; }
}
function startCountdown(){
  clearInterval(cdTimer); cdVal=REFRESH;
  const fill=document.getElementById('cd-fill'), num=document.getElementById('cd-num');
  fill.style.transition='none'; fill.style.width='100%';
  void fill.offsetWidth;
  fill.style.transition=`width ${REFRESH}s linear`; fill.style.width='0%';
  cdTimer=setInterval(()=>{ num.textContent=--cdVal; if(cdVal<=0){ clearInterval(cdTimer); fetchStatus().then(startCountdown); } },1000);
}
fetchStatus().then(startCountdown);
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = HTML.encode("utf-8")
            self._send(body, "text/html; charset=utf-8")
        elif self.path == "/api/status":
            body = json.dumps(get_status(), ensure_ascii=False).encode("utf-8")
            self._send(body, "application/json")
        else:
            self.send_error(404)

    def _send(self, body: bytes, ctype: str):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    url = f"http://localhost:{PORT}"
    print(f"\n  Process Monitoring Console  —  Web Interface")
    print(f"  Dashboard : {url}")
    print(f"  Settings  : {SETTINGS_FILE}")
    print(f"  State     : {STATE_FILE}")
    print("  Stop      : Ctrl+C\n")
    webbrowser.open(url)
    HTTPServer(("localhost", PORT), Handler).serve_forever()
