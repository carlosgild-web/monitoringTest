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

BASE          = Path(__file__).parent.parent.resolve()
SETTINGS_FILE = BASE / "monitoring_settings.json"
STATE_FILE    = BASE / "logs" / "process_state.json"
PORT          = 5758


def _parse_dt(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


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
    engine_ok    = age_sec is not None and age_sec < (max_interval * 2 + 15)

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
    return {
        "engine":        {"ok": engine_ok, "updated": updated_str,
                          "age_sec": age_sec, "pid": state.get("monitor_pid")},
        "processes":     processes,
        "total":         len(processes),
        "running_count": running_count,
        "server_time":   datetime.now().strftime("%H:%M:%S"),
        "version":       cfg.get("_meta", {}).get("version", "?"),
    }


HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Process Monitoring Console</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0d1a30;--bg2:#111f38;--bg3:#162543;--card:#162543;
  --border:#243758;--text:#cdddf5;--muted:#607898;
  --cyan:#2dd4dc;--green:#22d45a;--green-dim:#155f2b;
  --red:#f04040;--red-dim:#6b1c1c;--orange:#ff9940;--yellow:#f4c435;
}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;min-height:100vh}

/* ── TOP BAR ── */
.topbar{background:var(--bg2);border-bottom:1px solid var(--border);padding:14px 28px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:10}
.topbar-left{display:flex;align-items:center;gap:14px}
.app-icon{width:34px;height:34px;background:linear-gradient(135deg,#1a7fbf,var(--cyan));border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:17px;flex-shrink:0}
.app-title{font-size:17px;font-weight:700;color:#fff;letter-spacing:.2px}
.app-sub{font-size:12px;color:var(--muted);margin-top:2px}
.topbar-right{display:flex;align-items:center;gap:10px}
.version-badge{background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:3px 11px;font-size:11px;color:var(--muted)}
.refresh-indicator{display:flex;align-items:center;gap:7px;font-size:12px;color:var(--muted)}
.pulse-dot{width:7px;height:7px;border-radius:50%;background:var(--green);animation:pulse 2.5s ease-in-out infinite;flex-shrink:0}
.pulse-dot.off{background:var(--muted);animation:none}

/* ── ENGINE BAR ── */
.engine-bar{background:var(--bg3);border-bottom:1px solid var(--border);padding:10px 28px;display:flex;align-items:center;gap:20px;flex-wrap:wrap}
.engine-label{font-size:10px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:var(--muted);white-space:nowrap}
.engine-status{display:flex;align-items:center;gap:7px;font-size:13px;font-weight:600;white-space:nowrap}
.sdot{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.sdot-green{background:var(--green);box-shadow:0 0 7px rgba(34,212,90,.55)}
.sdot-red{background:var(--red);box-shadow:0 0 7px rgba(240,64,64,.55)}
.sdot-gray{background:var(--muted)}
.engine-health{font-size:12px}
.clr-green{color:var(--green)}
.clr-orange{color:var(--orange)}
.clr-muted{color:var(--muted)}

/* ── STATS ── */
.stats-row{padding:14px 28px;display:flex;gap:8px;flex-wrap:wrap}
.stat-pill{background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:5px 14px;font-size:12px;color:var(--muted);display:flex;align-items:center;gap:6px}
.stat-pill .num{font-weight:700;font-size:13px}
.stat-pill.s-run{border-color:var(--green-dim)}.stat-pill.s-run .num{color:var(--green)}
.stat-pill.s-dwn{border-color:var(--red-dim)}.stat-pill.s-dwn .num{color:var(--red)}

/* ── MAIN ── */
.main{padding:0 28px 80px}
.section-label{font-size:10px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:var(--muted);margin-bottom:12px;display:flex;align-items:center;gap:10px}
.section-label::after{content:'';flex:1;height:1px;background:var(--border)}

/* ── PROCESS ROW ── */
.proc-row{background:var(--card);border:1px solid var(--border);border-radius:10px;margin-bottom:10px;display:flex;align-items:stretch;overflow:hidden;transition:border-color .2s,box-shadow .2s}
.proc-row:hover{border-color:#3a5590;box-shadow:0 2px 16px rgba(0,0,0,.25)}
.row-accent{width:5px;flex-shrink:0}
.ac-green{background:#188c38}.ac-red{background:#8c1c1c}.ac-gray{background:var(--muted)}
.row-body{flex:1;padding:16px 22px;display:flex;align-items:center;gap:16px;min-width:0;flex-wrap:wrap}
.proc-name-col{min-width:160px;flex-shrink:0}
.proc-name{font-size:16px;font-weight:700;color:#fff}
.proc-exe{font-size:11px;color:var(--muted);margin-top:3px}
.status-col{min-width:145px;flex-shrink:0}
.sbadge{display:flex;align-items:center;gap:7px;font-size:13px;font-weight:700}
.sbadge-green{color:var(--green)}.sbadge-red{color:var(--red)}.sbadge-gray{color:var(--muted)}
.info-col{flex:1;min-width:160px}
.txt-orange{font-size:12px;color:var(--orange)}
.txt-muted{font-size:12px;color:var(--muted)}
.txt-alert{font-size:11px;color:var(--muted);margin-top:2px}
.tags{display:flex;gap:5px;margin-top:6px;flex-wrap:wrap}
.tag{font-size:10px;padding:2px 8px;border-radius:4px;background:var(--bg2);border:1px solid var(--border);color:var(--muted)}
.actions-col{flex-shrink:0}
.btn-instr{background:var(--red);color:#fff;border:none;border-radius:7px;padding:8px 16px;font-size:12px;font-weight:700;cursor:pointer;letter-spacing:.3px;transition:background .15s,transform .1s;white-space:nowrap}
.btn-instr:hover{background:#c82020;transform:scale(1.03)}
.empty{text-align:center;padding:56px;color:var(--muted)}

/* ── MODAL ── */
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.65);display:none;align-items:center;justify-content:center;z-index:200;backdrop-filter:blur(3px)}
.overlay.open{display:flex}
.modal{background:var(--bg2);border:1px solid var(--border);border-radius:14px;padding:30px 32px;max-width:490px;width:calc(100% - 32px);box-shadow:0 24px 64px rgba(0,0,0,.55);animation:slideUp .22s ease}
.modal-head{display:flex;align-items:flex-start;gap:14px;margin-bottom:22px}
.modal-icon-wrap{width:44px;height:44px;border-radius:10px;background:var(--red-dim);border:1px solid #a02020;display:flex;align-items:center;justify-content:center;font-size:22px;flex-shrink:0}
.modal-title{font-size:18px;font-weight:700;color:#fff;margin-bottom:3px}
.modal-exe{font-size:12px;color:var(--muted)}
.mrow{margin-bottom:18px}
.mrow-label{font-size:10px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:var(--muted);margin-bottom:6px}
.mrow-val{font-size:13px;color:var(--text)}
.mrow-val.red{color:var(--red)}.mrow-val.orange{color:var(--orange)}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{display:inline-flex;align-items:center;gap:5px;background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:4px 13px;font-size:12px;color:var(--text)}
.modal-note{background:var(--bg3);border:1px solid var(--border);border-left:3px solid var(--orange);border-radius:8px;padding:13px 16px;font-size:13px;color:var(--muted);line-height:1.6;margin-bottom:22px;white-space:pre-line}
.btn-close{width:100%;padding:11px;background:var(--bg3);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:14px;font-weight:600;cursor:pointer;transition:background .15s}
.btn-close:hover{background:var(--border)}

/* ── FOOTER ── */
.footer{position:fixed;bottom:0;left:0;right:0;background:var(--bg2);border-top:1px solid var(--border);padding:9px 28px;display:flex;align-items:center;justify-content:space-between;font-size:12px;color:var(--muted);z-index:10}
.cdbar-wrap{display:flex;align-items:center;gap:8px}
.cdbar{width:72px;height:3px;background:var(--border);border-radius:2px;overflow:hidden}
.cdbar-fill{height:100%;background:var(--cyan);border-radius:2px;transition:width 1s linear}

/* ── ANIMATIONS ── */
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.25}}
@keyframes slideUp{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:translateY(0)}}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.fade-in{animation:fadeIn .25s ease}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="app-icon">📊</div>
    <div>
      <div class="app-title">Process Monitoring Console</div>
      <div class="app-sub">Live process status &amp; health dashboard</div>
    </div>
  </div>
  <div class="topbar-right">
    <span class="version-badge" id="ver">v—</span>
    <div class="refresh-indicator">
      <span class="pulse-dot" id="pdot"></span>
      <span id="refresh-lbl">Connecting…</span>
    </div>
  </div>
</div>

<div class="engine-bar">
  <span class="engine-label">Monitoring Engine</span>
  <div class="engine-status">
    <span class="sdot sdot-gray" id="edot"></span>
    <span id="etxt" style="color:var(--muted)">Connecting…</span>
  </div>
  <span class="engine-health" id="ehealth"></span>
</div>

<div class="stats-row">
  <div class="stat-pill"><span class="num" id="s-total">—</span>&nbsp;Monitored</div>
  <div class="stat-pill s-run"><span class="num" id="s-run">—</span>&nbsp;Running</div>
  <div class="stat-pill s-dwn"><span class="num" id="s-dwn">—</span>&nbsp;Not Running</div>
</div>

<div class="main">
  <div class="section-label">Processes</div>
  <div id="proc-list"><div class="empty">Loading…</div></div>
</div>

<div class="footer">
  <span id="footer-lbl">Last refresh: —</span>
  <div class="cdbar-wrap">
    Auto-refresh in <span id="cd-num">10</span>s
    <div class="cdbar"><div class="cdbar-fill" id="cd-fill" style="width:100%"></div></div>
  </div>
</div>

<!-- INSTRUCTIONS MODAL -->
<div class="overlay" id="overlay" onclick="if(event.target===this)closeModal()">
  <div class="modal">
    <div class="modal-head">
      <div class="modal-icon-wrap">⚠️</div>
      <div>
        <div class="modal-title" id="m-title">Process Not Running</div>
        <div class="modal-exe"   id="m-exe"></div>
      </div>
    </div>

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
    <button class="btn-close" onclick="closeModal()">✕&nbsp; Close</button>
  </div>
</div>

<script>
const REFRESH = 10;
const ACT_ICONS = {popup:'🔔', log_to_file:'📝', email_draft:'📧', run_script:'⚙️'};
let cdTimer, cdVal = REFRESH;

function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

function fmtDur(sec){
  if(sec==null||sec<0) return '—';
  const h=Math.floor(sec/3600), m=Math.floor((sec%3600)/60), s=sec%60;
  if(h>0) return h+'h '+m+'m '+s+'s';
  if(m>0) return m+'m '+s+'s';
  return s+'s';
}

function render(d){
  // header
  document.getElementById('ver').textContent = 'v'+d.version;
  document.getElementById('refresh-lbl').textContent = 'Refreshed '+d.server_time;
  document.getElementById('footer-lbl').textContent  = 'Last refresh: '+d.server_time;

  // engine
  const eng = d.engine;
  const edot=document.getElementById('edot'), etxt=document.getElementById('etxt');
  const eh=document.getElementById('ehealth'), pd=document.getElementById('pdot');
  if(eng.ok){
    edot.className='sdot sdot-green';
    etxt.textContent='ACTIVE'+(eng.pid?'  ·  PID '+eng.pid:'')+'  ·  process_monitor.ps1';
    etxt.style.color='var(--green)';
    eh.innerHTML='<span class="clr-green">State updated '+fmtDur(eng.age_sec)+' ago  ·  Checks are current</span>';
    pd.className='pulse-dot';
  } else if(eng.updated){
    edot.className='sdot sdot-red';
    etxt.textContent='STALLED — state file is '+fmtDur(eng.age_sec)+' old';
    etxt.style.color='var(--red)';
    eh.innerHTML='<span class="clr-orange">Monitor may have stopped — run start_monitoring.bat</span>';
    pd.className='pulse-dot off';
  } else {
    edot.className='sdot sdot-gray';
    etxt.textContent='NOT RUNNING — run start_monitoring.bat to begin';
    etxt.style.color='var(--muted)';
    eh.innerHTML='';
    pd.className='pulse-dot off';
  }

  // stats
  document.getElementById('s-total').textContent = d.total;
  document.getElementById('s-run').textContent   = d.running_count;
  document.getElementById('s-dwn').textContent   = d.total - d.running_count;

  // process rows
  const list = document.getElementById('proc-list');
  if(!d.processes.length){
    list.innerHTML='<div class="empty">No processes configured in monitoring_settings.json.</div>';
    return;
  }

  list.innerHTML = d.processes.map(p => {
    const run = p.is_running === true;
    const unk = p.is_running === null;
    const ac  = run?'ac-green':unk?'ac-gray':'ac-red';
    const bc  = run?'sbadge-green':unk?'sbadge-gray':'sbadge-red';
    const st  = run?'● RUNNING':unk?'● UNKNOWN':'● NOT RUNNING';

    let info = '';
    if(!run && p.down_since){
      info += `<div class="txt-orange">Down since: ${esc(p.down_since)}${p.down_sec!=null?' ('+fmtDur(p.down_sec)+')':''}</div>`;
      info += `<div class="txt-alert">Alerts sent: ${p.alert_count}</div>`;
    } else if(run && p.last_check){
      info += `<div class="txt-muted">Last check: ${esc(p.last_check)}</div>`;
    }
    if(p.actions&&p.actions.length){
      info += `<div class="tags">${p.actions.map(a=>`<span class="tag">${ACT_ICONS[a]||'•'} ${esc(a)}</span>`).join('')}</div>`;
    }

    const btn = !run
      ? `<button class="btn-instr" onclick='showModal(${JSON.stringify(p)})'>Click here for instructions</button>`
      : '';

    return `<div class="proc-row fade-in">
  <div class="row-accent ${ac}"></div>
  <div class="row-body">
    <div class="proc-name-col">
      <div class="proc-name">${esc(p.display_name)}</div>
      <div class="proc-exe">${esc(p.name)}&nbsp;·&nbsp;${p.required?'Required':'Optional'}&nbsp;·&nbsp;Check every ${p.check_sec}s</div>
    </div>
    <div class="status-col"><div class="sbadge ${bc}">${st}</div></div>
    <div class="info-col">${info}</div>
    <div class="actions-col">${btn}</div>
  </div>
</div>`;
  }).join('');
}

function showModal(p){
  document.getElementById('m-title').textContent  = p.display_name+' — Not Running';
  document.getElementById('m-exe').textContent    = p.name+(p.required?' · Required':' · Optional');
  document.getElementById('m-alerts').textContent = p.alert_count;

  const dr = document.getElementById('m-down-row');
  if(p.down_since){
    dr.style.display='';
    document.getElementById('m-down').textContent =
      p.down_since+(p.down_sec!=null?'  ('+fmtDur(p.down_sec)+')':'');
  } else { dr.style.display='none'; }

  const ar = document.getElementById('m-act-row');
  const chips = document.getElementById('m-chips');
  if(p.actions&&p.actions.length){
    ar.style.display='';
    chips.innerHTML = p.actions.map(a=>`<span class="chip">${ACT_ICONS[a]||'•'} ${esc(a)}</span>`).join('');
  } else { ar.style.display='none'; }

  document.getElementById('m-note').textContent = p.instructions ||
    (p.display_name+' ('+p.name+') is currently not running. '+
    (p.required?'This process is marked as Required. ':'')+
    'Start the process manually to stop alerts.');

  document.getElementById('overlay').classList.add('open');
}

function closeModal(){
  document.getElementById('overlay').classList.remove('open');
}

document.addEventListener('keydown', e=>{ if(e.key==='Escape') closeModal(); });

// ── fetch & countdown ──
async function fetchStatus(){
  try{
    const r = await fetch('/api/status');
    if(!r.ok) throw new Error('HTTP '+r.status);
    render(await r.json());
  } catch(e){
    document.getElementById('etxt').textContent='Error: '+e.message;
  }
}

function startCountdown(){
  clearInterval(cdTimer);
  cdVal = REFRESH;
  const fill=document.getElementById('cd-fill'), num=document.getElementById('cd-num');
  fill.style.transition='none'; fill.style.width='100%';
  void fill.offsetWidth;
  fill.style.transition=`width ${REFRESH}s linear`; fill.style.width='0%';
  cdTimer=setInterval(()=>{
    num.textContent=--cdVal;
    if(cdVal<=0){ clearInterval(cdTimer); fetchStatus().then(startCountdown); }
  },1000);
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
