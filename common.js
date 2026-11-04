/* common.js: what the three Stream Duel pages share (DESIGN.md).
 *   - the bar of page links and the "About the data" button, put into <nav id="pages">
 *   - the "About the data" dialog: what each drone sends, the rates and why, the cost per drone
 *     and at the current fleet, and why four metrics is the minimum
 *   - the launcher client (launcher.py on :5100), which runs start.sh and stop.sh for the pages
 * Each page sets SD.fleet to the fleet size it shows; the dialog reads it when it opens.
 * The styles borrow each page's own colour tokens, so the bar looks native on every page.
 */
(() => {
  "use strict";
  const PAGES = [
    ["fleet-wall.html", "Fleet wall", "Every drone, drawn live on the GPU"],
    ["live-data.html", "Live data", "The newest rows of both tables, as they arrive"],
    ["stream-duel.html", "kdb+ vs DuckDB", "Both engines on the same feed, measured live"],
  ];
  // what each drone sends (schema.q, gen.q): telem rows at 50 Hz, rotor rows at 100 Hz
  const RATES = { sensor: 200, telem: 50, rotor: 100 };
  const BYTES = { telem: 32, rotor: 24 };
  const PER_DRONE = {
    rows: RATES.telem + RATES.rotor,
    values: 3 * RATES.telem + RATES.rotor,
    bytes: BYTES.telem * RATES.telem + BYTES.rotor * RATES.rotor,
  };
  const fmt = (n) => Math.round(n).toLocaleString("en-US");
  const si = (n) => {
    for (const [d, s] of [[1e9, "B"], [1e6, "M"], [1e3, "K"]]) if (n >= d) return `${(n / d).toFixed(n / d < 10 ? 2 : 1)}${s}`;
    return fmt(n);
  };
  const bytes = (b) => {
    for (const [d, s] of [[1e9, "GB"], [1e6, "MB"], [1e3, "KB"]]) if (b >= d) return `${(b / d).toFixed(b / d < 10 ? 2 : 1)} ${s}`;
    return `${fmt(b)} B`;
  };

  /* ---- styles: tokens from whichever page this is (wall/table: --text --line --chip; duel: --ink --rule) ---- */
  const css = `
.sd-nav{display:flex;align-items:center;gap:8px;flex-wrap:wrap;font:inherit}
.sd-pages{display:flex;border:1px solid var(--line,var(--rule,#C3CCD9));border-radius:8px;padding:2px;gap:2px}
.sd-pages a{font:600 13.5px/1 inherit;font-family:inherit;color:var(--muted,var(--ink-2,#56636F));text-decoration:none;
  padding:6px 11px;border-radius:6px;white-space:nowrap}
.sd-pages a:hover{color:var(--text,var(--ink,#16212B))}
.sd-pages a[aria-current="page"]{background:var(--chip,var(--ink,#16212B));color:var(--chip-ink,var(--paper,#fff))}
.sd-about{font:600 13.5px/1 inherit;font-family:inherit;color:var(--text,var(--ink,#16212B));background:none;cursor:pointer;
  border:1px solid var(--line,var(--rule,#C3CCD9));border-radius:8px;padding:7px 11px;white-space:nowrap}
.sd-about:hover{border-color:var(--text,var(--ink,#16212B))}
.sd-pages a:focus-visible,.sd-about:focus-visible,.sd-dlg button:focus-visible{outline:2px solid var(--accent,var(--ink,#16212B));outline-offset:2px}
dialog.sd-dlg{width:min(760px,calc(100vw - 32px));max-height:min(88vh,980px);padding:0;border-radius:12px;
  border:1px solid var(--line,var(--rule,#C3CCD9));background:var(--panel,var(--paper,#fff));color:var(--text,var(--ink,#16212B));
  font-family:inherit;box-shadow:0 24px 60px -20px rgba(0,0,0,.45)}
dialog.sd-dlg::backdrop{background:rgba(4,10,20,.45)}
.sd-dlg .sd-in{padding:22px 26px 24px;overflow:auto;max-height:inherit}
.sd-dlg header{display:flex;align-items:baseline;justify-content:space-between;gap:16px;margin-bottom:6px}
.sd-dlg h2{margin:0;font-size:22px;font-weight:600}
.sd-dlg h3{margin:20px 0 6px;font-size:15px;font-weight:600}
.sd-dlg p{margin:6px 0;font-size:14px;line-height:1.5;max-width:68ch}
.sd-dlg .sd-muted{color:var(--muted,var(--ink-2,#56636F))}
.sd-dlg .sd-x{font:inherit;font-size:14px;background:none;border:1px solid var(--line,var(--rule,#C3CCD9));
  color:inherit;border-radius:8px;padding:5px 10px;cursor:pointer}
.sd-dlg table{border-collapse:collapse;width:100%;font-size:13.5px;margin:4px 0 2px;font-variant-numeric:tabular-nums}
.sd-dlg th,.sd-dlg td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line,var(--rule,#C3CCD9));vertical-align:top}
.sd-dlg th{font-weight:600;color:var(--muted,var(--ink-2,#56636F));font-size:12.5px}
.sd-dlg td.n,.sd-dlg th.n{text-align:right}
.sd-dlg code{font-family:var(--mono,ui-monospace,Menlo,monospace);font-size:12.5px}
.sd-dlg .sd-cols{display:grid;grid-template-columns:1fr 1fr;gap:6px 22px}
.sd-dlg .sd-now{font-size:15px;margin:8px 0 2px}
.sd-dlg .sd-now b{font-size:18px}
@media (max-width:640px){.sd-dlg .sd-cols{grid-template-columns:1fr}.sd-dlg .sd-in{padding:18px 16px}}
`;
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);

  /* ---- the bar ---- */
  const here = decodeURIComponent(location.pathname).split("/").pop() || "stream-duel.html";
  const host = document.getElementById("pages");
  if (host) {
    host.className = "sd-nav";
    host.setAttribute("aria-label", "Pages");
    const group = document.createElement("div");
    group.className = "sd-pages";
    for (const [href, label, title] of PAGES) {
      const a = document.createElement("a");
      a.href = href; a.textContent = label; a.title = title;
      if (href === here) a.setAttribute("aria-current", "page");
      group.append(a);
    }
    const about = document.createElement("button");
    about.type = "button"; about.className = "sd-about"; about.textContent = "About the data";
    about.onclick = () => openAbout();
    host.append(group, about);
  }

  /* ---- the dialog ---- */
  const dlg = document.createElement("dialog");
  dlg.className = "sd-dlg";
  dlg.setAttribute("aria-labelledby", "sdAboutTitle");
  dlg.innerHTML = `<div class="sd-in">
<header><h2 id="sdAboutTitle">About the data</h2><button type="button" class="sd-x" autofocus>Close</button></header>
<p>Every drone senses at ${RATES.sensor} Hz and sends two tables to the tickerplant, at the rates the analysis needs and no more. All of it is synthetic, generated in q.</p>

<h3>What each row carries</h3>
<div class="sd-cols">
<div><p><code>telem</code>: ${RATES.telem} rows a second per drone, ${BYTES.telem} bytes each</p>
<table><thead><tr><th>Column</th><th>What it is</th></tr></thead><tbody>
<tr><td><code>time</code></td><td>tickerplant stamp: when the row entered the pipeline</td></tr>
<tr><td><code>stime</code></td><td>sample time: start of the row's 20 ms</td></tr>
<tr><td><code>uav</code></td><td>drone id</td></tr>
<tr><td><code>alt</code></td><td>altitude, m: mean of the 4 sensor samples in the 20 ms</td></tr>
<tr><td><code>ias</code></td><td>airspeed, m/s: mean, likewise</td></tr>
<tr><td><code>imuz</code></td><td>vertical acceleration, m/s²: mean, likewise</td></tr>
</tbody></table></div>
<div><p><code>rotor</code>: ${RATES.rotor} rows a second per drone, ${BYTES.rotor} bytes each</p>
<table><thead><tr><th>Column</th><th>What it is</th></tr></thead><tbody>
<tr><td><code>time</code></td><td>tickerplant stamp</td></tr>
<tr><td><code>stime</code></td><td>sample time</td></tr>
<tr><td><code>uav</code></td><td>drone id</td></tr>
<tr><td><code>rpm</code></td><td>rotor speed: every second sensor sample</td></tr>
</tbody></table></div>
</div>

<h3>Why these rates</h3>
<p>The analysis works on ${RATES.telem} Hz telemetry: shapes as fast as a 3 Hz jink, half-second anomalies, 4-second windows. Averaging 4 samples on the drone is the filter a sensor applies before it sends fewer samples, so nothing the analysis uses is lost.</p>
<p>The rotor's signature lives between 5 and 40 Hz, which needs more than 80 samples a second. At ${RATES.rotor} Hz, 256 samples (2.56 s) tell frequencies 0.39 Hz apart: enough to tell a 17 Hz rotor from the same rotor laden, 8% slower at 15.6 Hz.</p>

<h3>Per drone, per second</h3>
<table><thead><tr><th></th><th class="n">All 4 metrics at ${RATES.sensor} Hz</th><th class="n">What each drone sends</th><th class="n">Saved</th></tr></thead><tbody>
<tr><td>Rows</td><td class="n">${fmt(RATES.sensor)}</td><td class="n">${fmt(PER_DRONE.rows)}</td><td class="n">${Math.round(100 - (100 * PER_DRONE.rows) / RATES.sensor)}%</td></tr>
<tr><td>Metric values</td><td class="n">${fmt(4 * RATES.sensor)}</td><td class="n">${fmt(PER_DRONE.values)}</td><td class="n">${Math.round(100 - (100 * PER_DRONE.values) / (4 * RATES.sensor))}%</td></tr>
<tr><td>Bytes</td><td class="n">${fmt(36 * RATES.sensor)}</td><td class="n">${fmt(PER_DRONE.bytes)}</td><td class="n">${Math.round(100 - (100 * PER_DRONE.bytes) / (36 * RATES.sensor))}%</td></tr>
</tbody></table>

<h3>At the current fleet</h3>
<p class="sd-now" id="sdNow"></p>

<h3>Why four metrics is the minimum</h3>
<p>Each metric is the only source for at least one of the seven things the analysis finds.</p>
<table><thead><tr><th>Metric</th><th>Used to find</th><th>Without it</th></tr></thead><tbody>
<tr><td>Altitude</td><td>dives, hidden swarms</td><td>dives lose their main shape, and swarms are left with one channel, where chance correlations among a thousand drones form false groups</td></tr>
<tr><td>Airspeed</td><td>dives, hover and stare, hidden swarms</td><td>hover and stare is lost (its only channel); dives and swarms weaken</td></tr>
<tr><td>Vertical acceleration</td><td>payload release, evasive jinking, jamming</td><td>all three are lost</td></tr>
<tr><td>Rotor speed</td><td>airframe class, laden rotor</td><td>both are lost</td></tr>
</tbody></table>
<p class="sd-muted">Every figure on these pages is measured from this data as it streams.</p>
</div>`;
  document.body.append(dlg);
  dlg.querySelector(".sd-x").onclick = () => dlg.close();
  dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });  // a click on the backdrop
  function openAbout() {
    const n = SD.fleet;
    dlg.querySelector("#sdNow").innerHTML = n == null ? "Not connected to the system yet."
      : n === 0 ? "The fleet is off: no drones are flying."
      : `<b>${fmt(n)}</b> drone${n === 1 ? "" : "s"} send <b>${si(n * PER_DRONE.rows)}</b> rows, <b>${si(n * PER_DRONE.values)}</b> metric values and <b>${bytes(n * PER_DRONE.bytes)}</b> a second.`;
    dlg.showModal();
  }

  /* ---- the launcher client ---- */
  const launch = {
    url: "ws://localhost:5100", ws: null, up: false, state: "idle", detail: "", subs: [],
    send(cmd) { if (this.ws && this.ws.readyState === 1) { this.ws.send(JSON.stringify({ cmd })); return true; } return false; },
    on(fn) { this.subs.push(fn); fn(this); },
    tell() { for (const f of this.subs) f(this); },
  };
  function connectLauncher() {
    let ws;
    try { ws = new WebSocket(launch.url); } catch (_) { setTimeout(connectLauncher, 2000); return; }
    launch.ws = ws;
    ws.onopen = () => { launch.up = true; launch.tell(); };
    ws.onclose = () => { launch.up = false; launch.tell(); setTimeout(connectLauncher, 2000); };
    ws.onerror = () => {};
    ws.onmessage = (e) => {
      let m; try { m = JSON.parse(e.data); } catch (_) { return; }
      if (m.type !== "launcher") return;
      launch.state = m.state; launch.detail = m.detail || ""; launch.tell();
    };
  }
  if (/^(file|http):$/.test(location.protocol)) connectLauncher();

  const SD = { PAGES, RATES, BYTES, PER_DRONE, fleet: null, launch, openAbout,
    dir: decodeURIComponent(location.pathname).replace(/\/[^/]*$/, "") || "." };
  window.SD = SD;
})();
