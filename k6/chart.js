#!/usr/bin/env node
// Turns the saved k6 summaries in results/ into a stand-alone SVG chart.
//
//   node k6/chart.js                          # steady scenario -> results/charts/<UTC time>-steady.svg
//   node k6/chart.js --scenario ramp
//   node k6/chart.js --notes notes.txt        # add your own notes below the key numbers
//   node k6/chart.js --out somewhere/chart.svg  # one-off file; README left alone
//   node k6/chart.js --readme-only            # just point the README at the newest chart
//
// Every chart in results/charts/ is named <YYYY-MM-DD_HH-MM-SS>-<scenario>.svg
// (UTC), and after writing one the "Latest results" block in README.md is
// updated to show the newest chart in that folder.
//
// Reads results/<target>-<scenario>-<n>.json (written by k6/run-all.sh) and,
// when present, results/info/<target>-<scenario>.json (versions and machine
// details, also written by run-all.sh).
//
// Notes file: one note per line; blank lines and lines starting with # are
// ignored. A leading "**Some words.**" is shown in bold.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

// ---------- options ----------
const args = process.argv.slice(2);
const opt = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const ROOT = path.resolve(__dirname, '..');
const RESULTS = path.join(ROOT, 'results');
const scenario = opt('--scenario', 'steady');
const CHARTS = path.join(RESULTS, 'charts');
const README = path.join(ROOT, 'README.md');
const stamp = new Date().toISOString().slice(0, 19).replace('T', '_').replace(/:/g, '-');
const customOut = args.includes('--out');
const out = path.resolve(opt('--out', path.join(CHARTS, `${stamp}-${scenario}.svg`)));

// ---------- README: always show the newest timestamped chart ----------
const README_START = '<!-- latest-chart:start -->';
const README_END = '<!-- latest-chart:end -->';
function updateReadme() {
    const charts = (fs.existsSync(CHARTS) ? fs.readdirSync(CHARTS) : [])
        .filter(f => /^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-.+\.svg$/.test(f))
        .sort();
    if (!charts.length) { console.error('No charts in results/charts/ to link from the README.'); return false; }
    const latest = charts.at(-1);
    const [, d, t, scen] = latest.match(/^(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2})-\d{2}-(.+)\.svg$/);
    const block = [
        README_START,
        `Latest results (${d} ${t.replace('-', ':')} UTC, ${scen} scenario). Earlier charts are in [\`results/charts/\`](results/charts/).`,
        '',
        `![Latest results](results/charts/${latest})`,
        README_END,
    ].join('\n');
    let readme = fs.readFileSync(README, 'utf8');
    const a = readme.indexOf(README_START), b = readme.indexOf(README_END);
    if (a >= 0 && b > a) {
        readme = readme.slice(0, a) + block + readme.slice(b + README_END.length);
    } else if (readme.includes('\n## Results\n')) {
        readme = readme.replace('\n## Results\n', `\n## Results\n\n${block}\n`);
    } else {
        readme += `\n## Results\n\n${block}\n`;
    }
    fs.writeFileSync(README, readme);
    console.log(`README now shows results/charts/${latest}`);
    return true;
}
if (args.includes('--readme-only')) process.exit(updateReadme() ? 0 : 1);
const notesFile = opt('--notes', process.env.CHART_NOTES || '');

// Must match the scenarios in k6/smackdown.js.
const SCENARIOS = {
    steady: '10 virtual users for 30 s',
    ramp: '10 → 100 virtual users over 1 min, then 30 s at 100',
};

// Display names, in the order used when medians tie.
const TARGETS = {
    go: { name: 'Go', framework: 'net/http' },
    rust: { name: 'Rust', framework: 'axum' },
    dotnet: { name: '.NET', framework: 'minimal API' },
    'node-cluster': { name: 'Node (all cores)', framework: 'Express cluster' },
    node: { name: 'Node (one process)', framework: 'Express' },
    python: { name: 'Python', framework: 'FastAPI' },
};

// ---------- load results ----------
const files = fs.existsSync(RESULTS) ? fs.readdirSync(RESULTS) : [];
const byTarget = {};
for (const f of files) {
    const m = f.match(/^(.+)-([a-z]+)-(\d+)\.json$/);
    if (!m || m[2] !== scenario) continue;
    const file = path.join(RESULTS, f);
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    const M = j.metrics || {};
    if (!M.http_reqs || !M.http_req_duration) continue;
    const checks = Object.values((j.root_group && j.root_group.checks) || {});
    (byTarget[m[1]] ??= []).push({
        run: Number(m[3]),
        rps: M.http_reqs.rate,
        count: M.http_reqs.count,
        avg: M.http_req_duration.avg * 1000,
        p95: M.http_req_duration['p(95)'] * 1000,
        failedRate: M.http_req_failed ? M.http_req_failed.value : 0,
        checkFails: checks.reduce((n, c) => n + (c.fails || 0), 0),
        mtime: fs.statSync(file).mtime,
    });
}
if (!Object.keys(byTarget).length) {
    console.error(`No results for scenario "${scenario}" in ${RESULTS}. Run k6/run-all.sh first.`);
    process.exit(1);
}

const median = a => {
    const s = [...a].sort((x, y) => x - y);
    const mid = Math.floor(s.length / 2);
    return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};
const readInfo = t => {
    const f = path.join(RESULTS, 'info', `${t}-${scenario}.json`);
    try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return {}; }
};

const rows = Object.entries(byTarget).map(([t, runs]) => {
    runs.sort((a, b) => a.run - b.run);
    const info = readInfo(t);
    const meta = TARGETS[t] || { name: t, framework: '' };
    const detail = [info.framework || meta.framework, info.runtime].filter(Boolean).join(' · ');
    return {
        target: t,
        name: meta.name,
        detail,
        info,
        runs,
        med: median(runs.map(r => r.rps)),
        p95: median(runs.map(r => r.p95)),
        avg: median(runs.map(r => r.avg)),
        lo: Math.min(...runs.map(r => r.rps)),
        hi: Math.max(...runs.map(r => r.rps)),
        failedRuns: runs.filter(r => r.failedRate > 0 || r.checkFails > 0).length,
        last: new Date(Math.max(...runs.map(r => +r.mtime))),
    };
});
const order = Object.keys(TARGETS);
rows.sort((a, b) => b.med - a.med || order.indexOf(a.target) - order.indexOf(b.target));

// ---------- formatting helpers ----------
const fmt = n => Math.round(n).toLocaleString('en-US');
const k = n => (n / 1000).toFixed(1) + 'k';
const pct = x => Math.round(x * 100) + '%';
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const list = names => names.length < 2 ? names.join('') : names.slice(0, -1).join(', ') + ' and ' + names.at(-1);

// ---------- key numbers (calculated) ----------
const bullets = [];
const top = rows[0], bottom = rows.at(-1);
if (rows.length > 1) {
    bullets.push([
        `${top.name} handled the most requests:`,
        `${fmt(top.med)} req/s, ${(top.med / bottom.med).toFixed(1)}× ${bottom.name} (${fmt(bottom.med)} req/s). ` +
        `Full order: ${rows.map(r => r.name).join(', ')}.`,
    ]);
    const byP95 = [...rows].sort((a, b) => a.p95 - b.p95);
    bullets.push([
        `Lowest p95 latency: ${byP95[0].name}, ${Math.round(byP95[0].p95)} µs.`,
        `Highest: ${byP95.at(-1).name}, ${Math.round(byP95.at(-1).p95)} µs.`,
    ]);
} else {
    bullets.push([`${top.name}:`, `${fmt(top.med)} req/s, p95 latency ${Math.round(top.p95)} µs.`]);
}
const single = rows.find(r => r.target === 'node'), cluster = rows.find(r => r.target === 'node-cluster');
if (single && cluster) {
    const gain = cluster.med / single.med - 1;
    bullets.push([
        `Node on all cores vs one process:`,
        `${gain >= 0 ? pct(gain) + ' more' : pct(-gain) + ' fewer'} requests per second.` +
        (gain < 0.25 ? ' A small gain like this suggests the load tester, not Node, was the limit.' : ''),
    ]);
}
const multi = rows.filter(r => r.runs.length > 1);
if (multi.length > 1) {
    const spread = r => (r.hi - r.lo) / r.med;
    const wobbly = [...multi].sort((a, b) => spread(b) - spread(a));
    const rest = Math.max(...wobbly.slice(1).map(spread));
    bullets.push(spread(wobbly[0]) > 2 * rest && spread(wobbly[0]) > 0.03
        ? [`${wobbly[0].name} varied the most between runs:`,
           `${k(wobbly[0].lo)}–${k(wobbly[0].hi)} req/s. The others stayed within ${pct(Math.max(rest, 0.01))}.`]
        : [`Runs were consistent:`, `every server stayed within ${pct(Math.max(spread(wobbly[0]), 0.01))} of its median.`]);
}
const totalRuns = rows.reduce((n, r) => n + r.runs.length, 0);
const failing = rows.filter(r => r.failedRuns);
bullets.push(failing.length
    ? [`Some runs had errors:`, `${list(failing.map(r => `${r.name} (${r.failedRuns} of ${r.runs.length} runs)`))} had failed requests or wrong responses. Treat their numbers with care.`]
    : [totalRuns === 1 ? `The run passed.` : `Every run passed.`, `${totalRuns === 1 ? 'It' : `All ${totalRuns} runs`} had zero failed requests, and every response had the expected body.`]);
const counts = [...new Set(rows.map(r => r.runs.length))];
if (counts.length > 1) {
    bullets.push([`Uneven run counts:`, rows.map(r => `${r.name} ${r.runs.length}`).join(', ') + '.']);
}

// ---------- notes (from the user) ----------
let notes = [];
if (notesFile) {
    notes = fs.readFileSync(path.resolve(notesFile), 'utf8').split('\n')
        .map(l => l.trim().replace(/^[-*]\s+/, ''))
        .filter(l => l && !l.startsWith('#'))
        .map(l => {
            const m = l.match(/^\*\*(.+?)\*\*\s*(.*)$/);
            return m ? [m[1], m[2]] : ['', l];
        });
}

// ---------- header text ----------
const infos = rows.map(r => r.info);
const first = key => (infos.find(i => i[key]) || {})[key];
const cpu = first('cpu') || (os.cpus()[0] || {}).model || 'unknown CPU';
const threads = first('threads') || os.cpus().length;
const serverCpus = first('server_cpus'), k6Cpus = first('k6_cpus');
const k6v = first('k6');
const when = new Date(Math.max(...rows.map(r => +r.last)));
const month = when.toLocaleString('en-US', { month: 'long', year: 'numeric' });
const runCounts = counts.length === 1 ? `${counts[0]} measured run${counts[0] > 1 ? 's' : ''} each` : 'measured runs vary';
const meta1 = `“Hello world” GET, identical 25-byte response · load from ${k6v ? 'k6 ' + k6v : 'k6'}, ` +
    `${SCENARIOS[scenario] || scenario + ' scenario'}, 1 warm-up + ${runCounts}`;
const meta2 = `${cpu} (${threads} threads); server and load tester on the same machine, ` +
    (serverCpus || k6Cpus ? `server pinned to cores ${serverCpus || 'any'}, k6 to ${k6Cpus || 'any'}` : 'cores not pinned');

// ---------- layout ----------
const W = 920, X0 = 210, LABEL_ROOM = 230, PLOT = W - X0 - LABEL_ROOM;
const niceStep = max => {
    const raw = max / 4, mag = 10 ** Math.floor(Math.log10(raw));
    return [1, 2, 2.5, 5, 10].map(m => m * mag).find(s => s >= raw);
};
const STEP = niceStep(top.med);
const MAX = Math.ceil(top.med / STEP) * STEP;
const sx = v => X0 + (v / MAX) * PLOT;
const tickLabel = v => v === 0 ? '0' : v >= 1e6 ? v / 1e6 + 'M' : v >= 1000 ? v / 1000 + 'k' : String(v);

// Rough text width so lines can be wrapped without a browser.
const textWidth = (s, size, bold) => s.length * size * (bold ? 0.58 : 0.53);
const wrap = (lead, rest, maxW, size) => {
    const lines = [];
    let line = [], width = lead ? textWidth(lead + ' ', size, true) : 0;
    for (const word of rest.split(/\s+/).filter(Boolean)) {
        const w = textWidth(word + ' ', size, false);
        if (width + w > maxW && (line.length || lines.length || lead)) {
            lines.push(line.join(' '));
            line = [];
            width = 0;
        }
        line.push(word);
        width += w;
    }
    lines.push(line.join(' '));
    return lines; // lines[0] follows the bold lead
};

const PLOT_TOP = 112, ROW = 62, BAR = 24;
const plotBottom = PLOT_TOP + ROW * rows.length;
let s = '';

for (let v = 0; v <= MAX; v += STEP) {
    const x = sx(v).toFixed(1);
    s += `<line class="${v === 0 ? 'base' : 'grid'}" x1="${x}" x2="${x}" y1="${PLOT_TOP}" y2="${plotBottom}"/>\n`;
    s += `<text class="tick" x="${x}" y="${plotBottom + 18}" text-anchor="middle">${tickLabel(v)}</text>\n`;
}
const medianOf = counts.length === 1 && counts[0] > 1 ? `median of ${counts[0]} runs` : 'median of the runs';
s += `<text class="axis-title" x="${X0}" y="${plotBottom + 40}">Requests per second, ${medianOf} (higher is better)</text>\n`;

rows.forEach((r, i) => {
    const cy = PLOT_TOP + ROW * i + ROW / 2;
    const y = cy - BAR / 2, x1 = sx(r.med), w = Math.max(x1 - X0, 5);
    const tip = `${r.name}${r.detail ? ' (' + r.detail + ')' : ''}: median ${fmt(r.med)} req/s; ` +
        `runs ${r.runs.map(x => fmt(x.rps)).join(', ')}; avg latency ${r.avg.toFixed(1)} µs, p95 ${r.p95.toFixed(1)} µs` +
        (r.failedRuns ? `; ${r.failedRuns} run(s) with errors` : '');
    const range = r.runs.length > 1 ? ` · runs ${k(r.lo)}–${k(r.hi)}` : '';
    s += `<g class="row" tabindex="0"><title>${esc(tip)}</title>\n`;
    s += `<rect class="hit" x="0" y="${cy - ROW / 2}" width="${W}" height="${ROW}"/>\n`;
    s += `<text class="name" x="${X0 - 14}" y="${cy - 2}" text-anchor="end">${esc(r.name)}</text>\n`;
    s += `<text class="sub" x="${X0 - 14}" y="${cy + 15}" text-anchor="end">${esc(r.detail)}</text>\n`;
    s += `<path class="bar" d="M${X0},${y} h${(w - 4).toFixed(1)} a4,4 0 0 1 4,4 v${BAR - 8} a4,4 0 0 1 -4,4 h-${(w - 4).toFixed(1)} z"/>\n`;
    s += `<text class="value" x="${(x1 + 10).toFixed(1)}" y="${cy - 2}">${fmt(r.med)} req/s${r.failedRuns ? ' ⚠' : ''}</text>\n`;
    s += `<text class="sub" x="${(x1 + 10).toFixed(1)}" y="${cy + 15}">p95 ${Math.round(r.p95)} µs${range}</text>\n`;
    s += `</g>\n`;
});

let y = plotBottom + 92;
const section = (title, items) => {
    s += `<text class="h2" x="24" y="${y}">${esc(title)}</text>\n`;
    y += 28;
    for (const [lead, rest] of items) {
        const lines = wrap(lead, rest, W - 44 - 24, 13.5);
        s += `<circle class="dot" cx="31" cy="${y - 5}" r="3"/>\n`;
        s += `<text class="body" x="44" y="${y}">${lead ? `<tspan class="lead">${esc(lead)}</tspan> ` : ''}${esc(lines[0])}</text>\n`;
        for (const line of lines.slice(1)) {
            y += 20;
            s += `<text class="body" x="44" y="${y}">${esc(line)}</text>\n`;
        }
        y += 30;
    }
};
s += `<line class="rule" x1="24" x2="${W - 24}" y1="${y - 34}" y2="${y - 34}"/>\n`;
section('Key numbers', bullets);
if (notes.length) { y += 10; section('Notes', notes); }
const H = Math.round(y + 6);

const title = `API Smackdown, ${month}: requests per second`;
const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-labelledby="t d" font-family="system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif">
<title id="t">${esc(title)}</title>
<desc id="d">${esc(`Median requests per second (${scenario} scenario): ` + rows.map(r => `${r.name} ${fmt(r.med)}`).join('; ') + '.')}</desc>
<style>
  svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --grid:#e1e0d9; --base:#c3c2b7; --bar:#2a78d6; --hover:#f1f0ec; }
  @media (prefers-color-scheme: dark) {
    svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --grid:#2c2c2a; --base:#383835; --bar:#3987e5; --hover:#242423; }
  }
  .bg { fill: var(--surface); }
  .grid { stroke: var(--grid); stroke-width: 1; }
  .base, .rule { stroke: var(--base); stroke-width: 1; }
  .bar { fill: var(--bar); }
  .hit { fill: transparent; }
  .row:hover .hit, .row:focus .hit { fill: var(--hover); }
  .row:focus { outline: none; }
  text { fill: var(--ink); }
  .h1 { font-size: 22px; font-weight: 700; }
  .h2 { font-size: 16px; font-weight: 700; }
  .meta, .sub, .tick, .axis-title { fill: var(--ink2); }
  .meta { font-size: 13px; }
  .name { font-size: 15px; font-weight: 600; }
  .sub { font-size: 12px; }
  .value { font-size: 15px; font-weight: 700; font-variant-numeric: tabular-nums; }
  .tick, .axis-title { font-size: 12px; }
  .body { font-size: 13.5px; }
  .lead { font-weight: 700; }
  .dot { fill: var(--ink2); }
</style>
<rect class="bg" width="100%" height="100%"/>
<text class="h1" x="24" y="40">${esc(title)}</text>
<text class="meta" x="24" y="64">${esc(meta1)}</text>
<text class="meta" x="24" y="83">${esc(meta2)}</text>
${s}</svg>
`;

fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, svg);
console.log(`Chart written to ${path.relative(process.cwd(), out) || out} (${plural(rows.length, 'server')}, ${plural(totalRuns, 'run')})`);
if (!customOut) updateReadme();
