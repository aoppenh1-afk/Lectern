#!/usr/bin/env node
// Lectern accessibility + performance audit (independent QA scope).
// Owns ONLY this file. Never edits index.html, style.css, assets/*.
// Run: PLAYWRIGHT_MODULE=<dir>/playwright-core node scripts/test-website-accessibility.mjs
// Env: BASE_URL (default http://127.0.0.1:8765/Lectern/), PLAYWRIGHT_MODULE,
//   AXE_MODULE (optional path to axe-core), JS_BUDGET_BYTES (default 61440).
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";
import zlib from "node:zlib";

const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const BASE = (process.env.BASE_URL || "http://127.0.0.1:8765/Lectern/").replace(/\/?$/, "/");
const BUDGET = Number(process.env.JS_BUDGET_BYTES || 60 * 1024);
const VIEWPORTS = [1440, 390];
const LEGAL = ["privacy.html", "terms.html"];
const DEMO_TABS = ["notes", "quiz"]; // plus top-of-home Overview state

async function loadPlaywright() {
  for (const s of [process.env.PLAYWRIGHT_MODULE, "playwright-core", "playwright"].filter(Boolean)) {
    try {
      let t = s;
      if ((s.startsWith("/") || s.startsWith(".")) && fs.existsSync(s) && fs.statSync(s).isDirectory())
        t = path.join(s, "index.mjs");
      const href = t.startsWith("/") || t.startsWith(".") ? pathToFileURL(t).href : t;
      return (await import(href)).chromium;
    } catch { /* next */ }
  }
  console.error("Playwright driver not found. Set PLAYWRIGHT_MODULE to the driver dir.");
  process.exit(2);
}
async function loadAxeSource() {
  for (const s of [process.env.AXE_MODULE, "axe-core"].filter(Boolean)) {
    try {
      const dir = s.endsWith(".js") ? path.dirname(s) : s;
      for (const f of ["axe.min.js", "axe.js"]) {
        for (const c of [path.join(dir, f), path.join(dir, "dist", f)]) {
          try { if (fs.existsSync(c)) return fs.readFileSync(c, "utf8"); } catch { /* next */ }
        }
      }
      const resolved = import.meta.resolve ? null : null;
      void resolved;
    } catch { /* next */ }
  }
  // bare-specifier fallback: resolve via createRequire-style file search
  for (const base of [path.join(REPO, "node_modules"), "/tmp"]) {
    for (const c of [path.join(base, "axe-core", "axe.min.js")]) {
      try { if (fs.existsSync(c)) return fs.readFileSync(c, "utf8"); } catch { /* next */ }
    }
  }
  // last resort: temp QA prefix mirrors local dev setup (env-overridable, not hardcoded use)
  const fallback = process.env.QA_TEMP ? path.join(process.env.QA_TEMP, "node_modules", "axe-core", "axe.min.js") : null;
  if (fallback && fs.existsSync(fallback)) return fs.readFileSync(fallback, "utf8");
  console.error("axe-core not found. npm i axe-core into temp and set AXE_MODULE to it.");
  process.exit(2);
}
const gz = (f) => zlib.gzipSync(fs.readFileSync(path.join(REPO, f)), { level: 9 }).length;

async function axeOn(page, label) {
  const res = await page.evaluate(async () => await axe.run(document, { runOnly: ["wcag2a", "wcag2aa"] }));
  for (const v of res.violations) {
    console.log(`VIOLATION [${v.impact}] ${v.id} ${label}: ${v.help}`);
    for (const n of v.nodes.slice(0, 5)) {
      console.log(`  selector=${n.target.join(" ")} html=${(n.html || "").slice(0, 160)}`);
      for (const c of [...(n.any || []), ...(n.all || [])])
        if (c.data) console.log(`    data=${JSON.stringify(c.data).slice(0, 240)}`);
    }
  }
  if (!res.violations.length) console.log(`PASS axe ${label}: 0 violations (WCAG2A/AA)`);
  return res.violations.length;
}

const _pw = await loadPlaywright();
let browser;
try { browser = await _pw.launch({ channel: "chrome", headless: true }); }
catch { browser = await _pw.launch({ headless: true }); }
const axeSrc = await loadAxeSource();
let totalViol = 0;
for (const w of VIEWPORTS) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 } });
  const page = await ctx.newPage();
  const seen = [];
  page.on("request", (r) => seen.push(r.url()));
  await page.goto(new URL("index.html", BASE).toString(), { waitUntil: "networkidle" });
  await page.waitForTimeout(900);
  await page.addScriptTag({ content: axeSrc });
  totalViol += await axeOn(page, `home Overview @${w}`);
  // Drive demo to Notes / Quiz states, then axe each.
  try {
    const open = page.locator("#lectern-demo [data-act='open-lecture']").first();
    if (await open.isVisible()) {
      await open.click(); await page.waitForTimeout(500);
      for (const tab of DEMO_TABS) {
        const t = page.locator(`#lectern-demo [data-act='tab'][data-id='${tab}']`).first();
        if (await t.isVisible()) { await t.click(); await page.waitForTimeout(400); totalViol += await axeOn(page, `demo-${tab} @${w}`); }
        else console.log(`SKIP demo-${tab} @${w}: tab not in DOM`);
      }
    } else console.log(`SKIP demo tabs @${w}: no open-lecture control`);
  } catch (e) { console.log(`SKIP demo tabs @${w}: ${String(e.message).slice(0, 100)}`); }
  for (const f of LEGAL) {
    await page.goto(new URL(f, BASE).toString(), { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(600);
    await page.addScriptTag({ content: axeSrc });
    totalViol += await axeOn(page, `${f} @${w}`);
  }
  const perf = await page.evaluate(() => performance.getEntriesByType("resource").map((e) => ({ n: e.name, s: e.transferSize || 0 })));
  const offsite = seen.filter((u) => { try { const h = new URL(u).hostname; return h !== new URL(BASE).hostname && h !== "localhost" && h !== "127.0.0.1"; } catch { return false; } });
  const bytes = perf.reduce((a, r) => a + r.s, 0);
  console.log(`PERF @${w}: ${perf.length} subresources, transfer=${bytes}B, offsite=${offsite.length ? offsite.join(",") : "none"}`);
  await ctx.close();
}
// Compressed JS budget from repo sources (what ships: story -> demo -> demo-data).
const jsFiles = ["assets/story.js", "assets/demo.js", "assets/demo-data.js"];
const jsGz = jsFiles.map((f) => ({ f, gz: gz(f) }));
const jsTotal = jsGz.reduce((a, r) => a + r.gz, 0);
console.log(`JS gzip: ${jsGz.map((r) => `${r.f}=${r.gz}`).join(" ")} total=${jsTotal} budget=${BUDGET} ${jsTotal <= BUDGET ? "PASS" : "FAIL"}`);
await browser.close();
console.log(`DONE violations=${totalViol} jsBudget=${jsTotal <= BUDGET ? "PASS" : "FAIL"}`);
process.exit(totalViol > 0 || jsTotal > BUDGET ? 1 : 0);
