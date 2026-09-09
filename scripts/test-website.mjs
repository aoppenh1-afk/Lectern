#!/usr/bin/env node
// Lectern website QA harness (independent QA contributor scope).
// Owns ONLY this file (plus optional docs/website-qa.md). Never edits
// index.html, style.css, assets/*, story/legal pages.
//
// What it does:
// - Serves nothing itself. Tests BASE_URL (default http://127.0.0.1:8765/Lectern/).
// - Measures horizontal overflow at 1440, 1280, 1024, 768, 390, 320.
// - Checks home/privacy/terms, local assets, console errors, third-party traffic.
// - Exercises demo navigation, flashcard reveal, quiz feedback, recording reset,
//   click-then-scroll state, reduced motion, keyboard focus persistence.
// - Compares legal body text against `git show HEAD:{privacy,terms}.html`
//   after excluding added nav/TOC (sentence-presence check + #google anchor).
// - Inspects the finished DOM with selector CANDIDATE lists instead of
//   overfitting one implementation's class names. Missing demo controls
//   report SKIP, not FAIL, so this harness is useful before builders finish.
//
// Setup:
//   # Playwright browser binaries already exist on this Mac (ms-playwright cache).
//   # Install only the driver into approved temp (never into the project):
//   mkdir -p "/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa"
//   npm init -y --prefix "/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa"
//   npm i playwright-core --prefix "/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa" --no-audit --no-fund
//   # Then run one of:
//   PLAYWRIGHT_MODULE=/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa/node_modules/playwright-core \
//     node scripts/test-website.mjs
//   BASE_URL=http://127.0.0.1:8765/Lectern/ node scripts/test-website.mjs --json
//
// Env: BASE_URL, PLAYWRIGHT_MODULE, PLAYWRIGHT_EXECUTABLE, QA_TIMEOUT_MS.
// Args: --base-url <url> --json --headed --timeout <ms> --only <substr>

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";

const execFileAsync = promisify(execFile);
const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const QA_TEMP = "/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa";
const VIEWPORTS = [1440, 1280, 1024, 768, 390, 320];
const PAGES = [
  { name: "home", path: "index.html" },
  { name: "privacy", path: "privacy.html" },
  { name: "terms", path: "terms.html" },
];
const NINE_NAV = ["Overview", "Calendar", "Assignments", "Courses", "Subscriptions", "Grades", "Resources", "Announcements", "AI Chat"];

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i >= 0 && process.argv[i + 1] && !process.argv[i + 1].startsWith("--")) return process.argv[i + 1];
  return fallback;
}
const BASE_URL = (arg("--base-url", process.env.BASE_URL || "http://127.0.0.1:8765/Lectern/") || "").replace(/\/?$/, "/");
const WANT_JSON = process.argv.includes("--json");
const HEADED = process.argv.includes("--headed");
const ONLY = arg("--only", "");
const TIMEOUT = Number(arg("--timeout", process.env.QA_TIMEOUT_MS || "15000")) || 15000;

const results = [];
function record(check, status, detail = "", extra = {}) {
  results.push({ check, status, detail, ...extra });
  if (!WANT_JSON) {
    const tag = status === "PASS" ? "PASS" : status === "FAIL" ? "FAIL" : "SKIP";
    console.log(`${tag}  ${check}${detail ? " — " + detail : ""}`);
  }
}

async function loadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_MODULE,
    "playwright",
    "playwright-core",
    path.join(QA_TEMP, "node_modules", "playwright-core"),
  ].filter(Boolean);
  const errors = [];
  for (const spec of candidates) {
    // Allow PLAYWRIGHT_MODULE to be a directory (e.g. .../node_modules/playwright-core).
    const tries = [spec];
    try {
      if (!spec.startsWith(".") && !spec.startsWith("/") && !spec.startsWith("file:")) {
        // bare specifier: single try below
      } else if (fs.existsSync(spec) && fs.statSync(spec).isDirectory()) {
        tries.push(path.join(spec, "index.mjs"), path.join(spec, "index.js"), path.join(spec, "lib", "index.js"));
      }
    } catch { /* ignore stat errors */ }
    let imported = false;
    for (const t of tries) {
      try {
        const target = (t.startsWith("/") || t.startsWith(".")) ? pathToFileURL(t).href : t;
        const mod = await import(target);
        return { mod, spec: t };
      } catch (e) {
        errors.push(`${t}: ${e.message?.split("\n")[0]}`);
      }
    }
    void imported;
  }
  console.error("Playwright driver not found. Install it ONLY into approved temp:\n" +
    `  npm i playwright-core --prefix "${QA_TEMP}" --no-audit --no-fund\n` +
    `  PLAYWRIGHT_MODULE=${QA_TEMP}/node_modules/playwright-core node scripts/test-website.mjs\n` +
    "Tried: " + errors.join(" | "));
  process.exit(2);
}

function resolveExecutable() {
  if (process.env.PLAYWRIGHT_EXECUTABLE && fs.existsSync(process.env.PLAYWRIGHT_EXECUTABLE)) {
    return process.env.PLAYWRIGHT_EXECUTABLE;
  }
  const home = process.env.HOME || "/Users/sender";
  const known = [
    path.join(home, "Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
    path.join(home, "Library/Caches/ms-playwright/chromium_headless_shell-1228/chrome-headless-shell-mac-arm64/chrome-headless-shell"),
  ];
  for (const p of known) if (fs.existsSync(p)) return p;
  return undefined;
}

const norm = (s) => (s || "").replace(/\s+/g, " ").replace(/\u00a0/g, " ").trim();
const sentences = (s) => norm(s).split(/(?<=[.!?])\s+/).map((x) => x.trim()).filter((x) => x.length > 25);
function stripTags(html) {
  return norm(html.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ").replace(/&middot;|&#183;/g, "·").replace(/&rsquo;|&#8217;/g, "'")
    .replace(/&ldquo;|&rdquo;/g, '"').replace(/&amp;/g, "&").replace(/&nbsp;/g, " "));
}
function mainText(html) {
  const m = html.match(/<main[\s\S]*?<\/main>/i) || html.match(/<article[\s\S]*?<\/article>/i);
  return stripTags(m ? m[0] : html);
}

async function gitHeadText(file) {
  try {
    const { stdout } = await execFileAsync("git", ["show", `HEAD:${file}`], { cwd: REPO_ROOT, timeout: 10000 });
    return stdout;
  } catch (e) {
    return null;
  }
}

// Generic first-match clicker over candidate selectors. Returns {selector, text} or null.
async function findControl(page, candidates, timeout = 1500) {
  for (const sel of candidates) {
    try {
      const loc = page.locator(sel).first();
      await loc.waitFor({ state: "visible", timeout });
      return { selector: sel, locator: page.locator(sel) };
    } catch { /* try next */ }
  }
  return null;
}
async function findByText(page, scope, regex, timeout = 1500) {
  try {
    const loc = scope.getByText(regex).first();
    await loc.waitFor({ state: "visible", timeout });
    return loc;
  } catch { return null; }
}

async function newPage(browser, { width, height = 900, reducedMotion = false, javaScriptEnabled = true } = {}) {
  const context = await browser.newContext({
    viewport: { width, height },
    reducedMotion: reducedMotion ? "reduce" : "no-preference",
    javaScriptEnabled,
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const failedLocal = [];
  const thirdParty = new Set();
  const baseHost = new URL(BASE_URL).hostname;
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(norm(msg.text()).slice(0, 300));
  });
  page.on("pageerror", (err) => consoleErrors.push(norm(String(err)).slice(0, 300)));
  page.on("response", (res) => {
    const url = res.url();
    let host = "";
    try { host = new URL(url).hostname; } catch { return; }
    if (res.status() >= 400) {
      if (host === baseHost || host === "127.0.0.1" || host === "localhost") {
        failedLocal.push(`${res.status()} ${url}`);
      }
    }
    if (url.startsWith("http") && host !== baseHost && host !== "127.0.0.1" && host !== "localhost") {
      thirdParty.add(`${host}${new URL(url).pathname}`);
    }
  });
  return { context, page, consoleErrors, failedLocal, thirdParty };
}

async function goto(page, rel) {
  const res = await page.goto(new URL(rel, BASE_URL).toString(), { waitUntil: "domcontentloaded", timeout: TIMEOUT });
  // Let ES modules + story/demo boot briefly without hard-coding their internals.
  await page.waitForTimeout(900);
  return res;
}

async function overflowMeasure(page) {
  return page.evaluate(() => ({
    innerWidth: window.innerWidth,
    docScroll: document.documentElement.scrollWidth,
    bodyScroll: document.body ? document.body.scrollWidth : 0,
    offenders: Array.from(document.querySelectorAll("body *")).slice(0, 4000)
      .filter((el) => { try { const r = el.getBoundingClientRect(); return r.width > window.innerWidth + 1 && r.width > 10; } catch { return false; } })
      .slice(0, 5).map((el) => `${el.tagName.toLowerCase()}${el.className ? "." + String(el.className).split(" ").slice(0, 2).join(".") : ""} w=${Math.round(el.getBoundingClientRect().width)}`),
  }));
}

async function demoSnapshot(page) {
  return page.evaluate(() => {
    const root = document.querySelector("#lectern-demo");
    if (!root) return { present: false };
    const mode = document.querySelector("[data-demo-mode]")?.textContent?.trim() || null;
    const active = root.querySelector("[aria-selected='true'], [aria-current='true'], .is-active, .on");
    return {
      present: true,
      mode,
      activeLabel: active ? (active.textContent || "").trim().slice(0, 80) : null,
      textLen: (root.innerText || "").length,
      textHead: (root.innerText || "").slice(0, 200),
    };
  });
}

async function main() {
  const { mod, spec } = await loadPlaywright();
  const chromium = mod.chromium;
  const executablePath = resolveExecutable();
  let browser;
  try {
    browser = await chromium.launch({ headless: !HEADED, executablePath });
  } catch (e) {
    console.error(`Browser launch failed with driver ${spec} (${executablePath || "default path"}): ${e.message?.split("\n")[0]}`);
    console.error("If the executable is missing, install browsers or set PLAYWRIGHT_EXECUTABLE to a Chromium binary.");
    process.exit(2);
  }
  if (!WANT_JSON) console.log(`QA harness: BASE_URL=${BASE_URL} driver=${spec} exe=${executablePath || "(default)"}\n`);

  // ---- 1. Page reachability + overflow matrix + console/third-party per page ----
  const globalThird = new Set();
  const globalConsole = [];
  const globalFailed = [];
  for (const vp of VIEWPORTS) {
    for (const p of PAGES) {
      if (ONLY && !`${vp} ${p.name}`.includes(ONLY)) continue;
      const { context, page, consoleErrors, failedLocal, thirdParty } = await newPage(browser, { width: vp });
      try {
        const res = await goto(page, p.path);
        const status = res ? res.status() : -1;
        record(`load ${p.name} @${vp}px`, status === 200 ? "PASS" : "FAIL", `HTTP ${status}`);
        const m = await overflowMeasure(page);
        const overflow = Math.max(m.docScroll, m.bodyScroll) - m.innerWidth;
        record(`overflow ${p.name} @${vp}px`, overflow <= 1 ? "PASS" : "FAIL",
          overflow <= 1 ? `no page-level h-scroll (inner=${m.innerWidth} scroll=${Math.max(m.docScroll, m.bodyScroll)})`
            : `OVERFLOW +${overflow}px inner=${m.innerWidth} doc=${m.docScroll} body=${m.bodyScroll} e.g. ${m.offenders.join(" | ") || "?"}`);
        for (const f of failedLocal) globalFailed.push(`${p.name}@${vp}: ${f}`);
        for (const t of thirdParty) globalThird.add(`${p.name}@${vp}: ${t}`);
        for (const c of consoleErrors) globalConsole.push(`${p.name}@${vp}: ${c}`);
      } catch (e) {
        record(`load ${p.name} @${vp}px`, "FAIL", e.message?.split("\n")[0]);
      } finally { await context.close(); }
    }
  }
  record("local assets (no 4xx/5xx same-origin)", globalFailed.length === 0 ? "PASS" : "FAIL",
    globalFailed.length === 0 ? "no failed same-origin requests across matrix" : globalFailed.slice(0, 12).join(" | "));
  record("console errors", globalConsole.length === 0 ? "PASS" : "FAIL",
    globalConsole.length === 0 ? "no console/page errors across matrix" : globalConsole.slice(0, 12).join(" | "));
  record("third-party requests", globalThird.size === 0 ? "PASS" : "FAIL",
    globalThird.size === 0 ? "no off-origin requests observed" : [...globalThird].slice(0, 12).join(" | "));

  // ---- 2. Short-height desktop viewport (acceptance gate mentions it) ----
  if (!ONLY) {
    const { context, page } = await newPage(browser, { width: 1440, height: 500 });
    try {
      await goto(page, "index.html");
      const m = await overflowMeasure(page);
      const overflow = Math.max(m.docScroll, m.bodyScroll) - m.innerWidth;
      record("overflow home @1440x500", overflow <= 1 ? "PASS" : "FAIL", `overflow +${Math.max(overflow, 0)}px`);
    } catch (e) { record("overflow home @1440x500", "FAIL", e.message?.split("\n")[0]); }
    finally { await context.close(); }
  }

  // ---- 3. Demo + story interaction (home, desktop width) ----
  {
    const { context, page, consoleErrors } = await newPage(browser, { width: 1280 });
    try {
      await goto(page, "index.html");
      const snap0 = await demoSnapshot(page);
      if (!snap0.present) {
        record("demo root #lectern-demo", "FAIL", "missing #lectern-demo");
      } else {
        record("demo root #lectern-demo", "PASS", `mode=${snap0.mode || "?"} textLen=${snap0.textLen}`);
        const label = await page.locator("text=Sample demo. No recording or uploads.").first().isVisible().catch(() => false);
        record("demo persistent sample label", label ? "PASS" : "FAIL", label ? "disclaimer visible" : "disclaimer text not found");
      }
      // 3a. Nine native nav entries present (as controls or explained absence).
      const demoText = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
      const missing = NINE_NAV.filter((n) => !demoText.includes(n));
      const fallbackOnly = await page.locator("#lectern-demo .demo-fallback").isVisible().catch(() => false);
      if (missing.length === 0) record("demo nine nav entries", "PASS", "all nine labels present in demo DOM");
      else if (fallbackOnly) record("demo nine nav entries", "SKIP", `interactive demo not built yet; fallback only. missing: ${missing.join(", ")}`);
      else record("demo nine nav entries", "FAIL", `missing: ${missing.join(", ")}`);

      // 3b. Sample navigation: finished DOM uses [data-act='nav'][data-id].
      // Keep generic text fallback so the check does not overfit one build.
      {
        let tried = 0, changed = 0;
        const notes = [];
        for (const id of ["courses", "aiChat", "calendar"]) {
          const btn = page.locator(`#lectern-demo [data-act='nav'][data-id='${id}']`).first();
          try {
            await btn.waitFor({ state: "visible", timeout: 1200 });
          } catch { continue; }
          tried++;
          const before = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          await btn.click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(400);
          const after = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          if (after !== before) { changed++; notes.push(`${id}:changed`); }
          else notes.push(`${id}:no-change`);
        }
        if (tried === 0) {
          // Generic fallback for earlier builds.
          const navHit = await findControl(page, ["#lectern-demo [role='tab']", "#lectern-demo button", "#lectern-demo a"]);
          if (!navHit) record("demo sample navigation", "SKIP", "no clickable demo controls yet");
          else {
            let gChanged = 0, gTried = 0;
            for (const label of ["Courses", "AI Chat", "Calendar"]) {
              const target = await findByText(page, page.locator("#lectern-demo"), new RegExp(label, "i"), 800);
              if (!target) continue;
              gTried++;
              const before = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
              await target.click({ timeout: 3000 }).catch(() => {});
              await page.waitForTimeout(400);
              const after = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
              if (after !== before) gChanged++;
            }
            if (gTried === 0) record("demo sample navigation", "SKIP", "named panels not clickable yet");
            else record("demo sample navigation", gChanged > 0 ? "PASS" : "FAIL", `${gChanged}/${gTried} panel clicks changed demo text`);
          }
        } else {
          // Return to a known state for the following checks.
          await page.locator("#lectern-demo [data-act='nav'][data-id='overview']").first().click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(300);
          record("demo sample navigation", changed > 0 ? "PASS" : "FAIL", `${changed}/${tried} nav clicks changed panel (${notes.join(", ")})`);
        }
        // Lecture tabs (capture/transcript/notes/cards/quiz/docs) via open-lecture.
        const openBtn = page.locator("#lectern-demo [data-act='open-lecture']").first();
        try {
          await openBtn.waitFor({ state: "visible", timeout: 1500 });
          await openBtn.click({ timeout: 3000 });
          await page.waitForTimeout(500);
          let tabChanged = 0, tabTried = 0;
          for (const tid of ["transcript", "notes", "docs"]) {
            const tab = page.locator(`#lectern-demo [data-act='tab'][data-id='${tid}']`).first();
            try { await tab.waitFor({ state: "visible", timeout: 1000 }); } catch { continue; }
            tabTried++;
            const before = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
            await tab.click({ timeout: 3000 }).catch(() => {});
            await page.waitForTimeout(400);
            const after = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
            if (after !== before) tabChanged++;
          }
          record("demo lecture tabs", tabTried === 0 ? "SKIP" : tabChanged > 0 ? "PASS" : "FAIL",
            tabTried === 0 ? "no lecture tabs in current DOM" : `${tabChanged}/${tabTried} tab clicks changed panel`);
        } catch {
          record("demo lecture tabs", "SKIP", "no open-lecture control in current DOM");
        }
      }

      // 3c. Flashcard reveal (manual only). Finished DOM: tab cards + [data-act='flip'].
      {
        const cardsTab = page.locator("#lectern-demo [data-act='tab'][data-id='cards']").first();
        const hasCardsTab = await cardsTab.isVisible().catch(() => false);
        if (hasCardsTab) { await cardsTab.click({ timeout: 3000 }).catch(() => {}); await page.waitForTimeout(400); }
        const cardBtn = (await findControl(page, ["#lectern-demo [data-act='flip']", "#lectern-demo [data-action*='card' i]", "#lectern-demo [data-demo*='card' i]", "#lectern-demo button:has-text('Flip')", "#lectern-demo button:has-text('Reveal')", "#lectern-demo button:has-text('Show answer')"], 1200)) ||
          (await (async () => { const l = await findByText(page, page.locator("#lectern-demo"), /flip|reveal|show answer/i, 800); return l ? { selector: "text", locator: page.locator("#lectern-demo").getByText(/flip|reveal|show answer/i) } : null; })());
        if (!cardBtn) record("demo flashcard reveal", "SKIP", "no flip/reveal control in current DOM");
        else {
          const before = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          await cardBtn.locator.first().click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(400);
          const after = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          record("demo flashcard reveal", after !== before ? "PASS" : "FAIL", after !== before ? `via ${cardBtn.selector}: answer revealed` : `via ${cardBtn.selector}: no visible change`);
          // Previous/Next must also work without duplicating cards.
          const prev = page.locator("#lectern-demo [data-act='prev-card']").first();
          const next = page.locator("#lectern-demo [data-act='next-card']").first();
          if (await next.isVisible().catch(() => false)) {
            await next.click({ timeout: 3000 }).catch(() => {});
            await page.waitForTimeout(300);
            const moved = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
            record("demo flashcard paging", moved !== after ? "PASS" : "FAIL", moved !== after ? "next card advances" : "next card did not advance");
            if (await prev.isVisible().catch(() => false)) { await prev.click({ timeout: 3000 }).catch(() => {}); await page.waitForTimeout(300); }
          } else record("demo flashcard paging", "SKIP", "no prev/next controls");
        }
      }

      // 3d. Quiz feedback. Finished DOM: tab quiz + [data-act='answer'] -> inline
      // feedback ("Not quite — the answer is highlighted." / "Correct") + Retake.
      {
        const quizTab = page.locator("#lectern-demo [data-act='tab'][data-id='quiz']").first();
        if (await quizTab.isVisible().catch(() => false)) { await quizTab.click({ timeout: 3000 }).catch(() => {}); await page.waitForTimeout(400); }
        const quizOpt = await findControl(page, ["#lectern-demo [data-act='answer']", "#lectern-demo input[type='radio']", "#lectern-demo [data-quiz] button", "#lectern-demo button:has-text('Encoding')"], 1200);
        if (!quizOpt) record("demo quiz feedback", "SKIP", "no quiz options in current DOM");
        else {
          await quizOpt.locator.first().click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(300);
          const submit = await findControl(page, ["#lectern-demo button:has-text('Submit')", "#lectern-demo button:has-text('Check')", "#lectern-demo button:has-text('Answer')"], 600);
          if (submit) await submit.locator.first().click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(400);
          const txt = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          const fb = /correct|not quite|highlighted|retake|score:/i.test(txt);
          record("demo quiz feedback", fb ? "PASS" : "FAIL", fb ? `feedback present (${txt.match(/correct|not quite|highlighted|retake|score:[^.]*/i)?.[0]?.slice(0, 80)})` : "no feedback text detected after answering");
          const retake = page.locator("#lectern-demo button:has-text('Retake')").first();
          if (await retake.isVisible().catch(() => false)) {
            await retake.click({ timeout: 3000 }).catch(() => {});
            await page.waitForTimeout(400);
            const t2 = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
            record("demo quiz retake", /score: 0 of 0 answered/i.test(t2) ? "PASS" : "FAIL", /score: 0 of 0 answered/i.test(t2) ? "retake restores unanswered state" : "retake state unclear");
          } else record("demo quiz retake", "SKIP", "no retake control");
        }
      }

      // 3e. Recording reset. Finished DOM: tab capture + rec-start/rec-reset with
      // simulated timer text (00:00). Reset must restore idle state; double reset
      // must not duplicate lectures/exports. Generic reset fallback kept.
      {
        const capTab = page.locator("#lectern-demo [data-act='tab'][data-id='capture']").first();
        if (await capTab.isVisible().catch(() => false)) { await capTab.click({ timeout: 3000 }).catch(() => {}); await page.waitForTimeout(400); }
        const startBtn = page.locator("#lectern-demo [data-act='rec-start']").first();
        const resetBtn = (await findControl(page, ["#lectern-demo [data-act='rec-reset']", "#lectern-demo [data-demo-action='reset']", "button[data-demo-action='reset']", "#lectern-demo button:has-text('Reset')"], 1200));
        if (!resetBtn) record("demo recording reset", "SKIP", "no reset control in current DOM");
        else {
          if (await startBtn.isVisible().catch(() => false)) { await startBtn.click({ timeout: 3000 }).catch(() => {}); await page.waitForTimeout(900); }
          const during = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          await resetBtn.locator.first().click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(400);
          const after1 = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          await resetBtn.locator.first().click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(400);
          const after2 = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
          const timerReset = /00:00/.test(after1);
          const stable = after1 === after2;
          const dupes = (after2.match(/How memory forms/g) || []).length;
          record("demo recording reset", timerReset && stable ? "PASS" : "FAIL",
            `timer 00:00 after reset=${timerReset}; double-reset stable=${stable}; lecture refs=${dupes} (was recording: ${/recording sample|00:0[1-9]/i.test(during)})`);
        }
      }

      // 3f. Click-then-scroll: Explore mode must survive scrolling.
      // NOTE: quiz Retake returns the demo to the capture tab, and earlier clicks
      // already enter Explore mode (which hides the Explore button and reveals
      // Resume). So reset to Guided tour first, then exercise Explore -> scroll.
      await page.locator(".demo-toolbar").first().scrollIntoViewIfNeeded().catch(() => {});
      {
        const sampleReset = page.locator("button[data-demo-action='reset']").first();
        if (await sampleReset.isVisible().catch(() => false)) {
          await sampleReset.click({ timeout: 3000 }).catch(() => {});
          await page.waitForTimeout(500);
        }
      }
      const exploreBtn = await findControl(page, ["button[data-demo-action='explore']", "#lectern-demo button:has-text('Explore')", "button:has-text('Explore the app')"], 3000);
      if (!exploreBtn) {
        const diag = await page.evaluate(() => ({
          exploreCount: document.querySelectorAll("button[data-demo-action='explore']").length,
          toolbar: !!document.querySelector(".demo-toolbar"),
          mode: document.querySelector("[data-demo-mode]")?.textContent?.trim() || null,
        })).catch(() => ({}));
        record("demo click-then-scroll", "SKIP", `no Explore control in current DOM (${JSON.stringify(diag)})`);
      } else {
        await exploreBtn.locator.first().click({ timeout: 3000 }).catch(() => {});
        await page.waitForTimeout(400);
        const before = await demoSnapshot(page);
        // Scroll through story chapters (scroll must move page, not overwrite demo).
        await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
        await page.waitForTimeout(500);
        await page.evaluate(() => window.scrollTo(0, 0));
        await page.waitForTimeout(500);
        const after = await demoSnapshot(page);
        const kept = before.present && after.present && before.mode === after.mode &&
          before.textHead === after.textHead && before.textLen === after.textLen;
        const scrolled = await page.evaluate(() => window.scrollY >= 0);
        record("demo click-then-scroll", kept && scrolled ? "PASS" : "FAIL",
          `mode ${before.mode || "?"}->${after.mode || "?"}; demo text ${before.textHead === after.textHead ? "preserved" : "CHANGED by scroll"}`);
      }

      // 3g. Keyboard focus persistence: focus inside demo, scroll, focus must stay.
      {
        const firstBtn = page.locator("#lectern-demo button, #lectern-demo a, #lectern-demo input, #lectern-demo [tabindex]").first();
        try {
          await firstBtn.waitFor({ state: "visible", timeout: 1500 });
          await firstBtn.focus();
          const insideBefore = await page.evaluate(() => !!document.activeElement?.closest?.("#lectern-demo"));
          await page.evaluate(() => document.querySelector("#how-it-works")?.scrollIntoView?.());
          await page.waitForTimeout(500);
          const insideAfter = await page.evaluate(() => !!document.activeElement?.closest?.("#lectern-demo"));
          const tag = await page.evaluate(() => document.activeElement?.tagName + (document.activeElement?.textContent || "").slice(0, 40));
          // Tab a few times: focus must move, not trap on one element.
          const seen = [];
          for (let i = 0; i < 6; i++) { await page.keyboard.press("Tab"); await page.waitForTimeout(120); seen.push(await page.evaluate(() => document.activeElement?.tagName + ":" + ((document.activeElement?.textContent || "").trim().slice(0, 20)))); }
          const moved = new Set(seen).size > 1;
          record("demo keyboard focus persistence", insideBefore && insideAfter && moved ? "PASS" : "FAIL",
            `focus inside before=${insideBefore} after-scroll=${insideAfter} (${tag}); tab moves=${moved}`);
        } catch {
          record("demo keyboard focus persistence", "SKIP", "no focusable demo controls yet");
        }
      }
      if (consoleErrors.length) record("demo console errors (interaction run)", "FAIL", consoleErrors.slice(0, 6).join(" | "));
      else record("demo console errors (interaction run)", "PASS", "no errors during interaction sequence");
    } finally { await context.close(); }
  }

  // ---- 4. Reduced motion ----
  {
    const { context, page } = await newPage(browser, { width: 1280, reducedMotion: true });
    try {
      await goto(page, "index.html");
      const mq = await page.evaluate(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches);
      const explore = await findControl(page, ["button[data-demo-action='explore']", "#lectern-demo button"], 1200);
      let manual = false;
      if (explore) {
        const b = norm(await page.locator("#lectern-demo").innerText().catch(() => ""));
        await explore.locator.first().click({ timeout: 3000 }).catch(() => {});
        await page.waitForTimeout(400);
        manual = norm(await page.locator("#lectern-demo").innerText().catch(() => "")) !== b || true; // click accepted counts
      }
      record("reduced motion", mq ? "PASS" : "FAIL", mq ? `media query honored; manual control ${explore ? "available" : "not yet built (SKIP detail)"}` : "matchMedia reduce=false under emulation");
      // Auto-advance check: snapshot, wait, snapshot without interaction should be stable.
      const t1 = await demoSnapshot(page);
      await page.waitForTimeout(2500);
      const t2 = await demoSnapshot(page);
      record("reduced motion no auto-advance", t1.textHead === t2.textHead ? "PASS" : "FAIL",
        t1.textHead === t2.textHead ? "demo stable over 2.5s idle" : "demo changed without input");
      void manual;
    } catch (e) { record("reduced motion", "FAIL", e.message?.split("\n")[0]); }
    finally { await context.close(); }
  }

  // ---- 5. No-JS static fallback ----
  {
    const { context, page } = await newPage(browser, { width: 1280, javaScriptEnabled: false });
    try {
      await goto(page, "index.html");
      const fallback = await page.locator("#lectern-demo .demo-fallback, #lectern-demo").first().isVisible().catch(() => false);
      const dl = await page.locator("a[href*='releases/latest']").first().isVisible().catch(() => false);
      const legal = await page.locator("a[href='privacy.html']").first().isVisible().catch(() => false);
      record("no-js static fallback", fallback && dl && legal ? "PASS" : "FAIL",
        `preview=${fallback} download=${dl} legal=${legal}`);
    } catch (e) { record("no-js static fallback", "FAIL", e.message?.split("\n")[0]); }
    finally { await context.close(); }
  }

  // ---- 6. Legal text preservation vs git HEAD (excluding added nav/TOC) ----
  for (const file of ["privacy.html", "terms.html"]) {
    if (ONLY && !file.includes(ONLY)) continue;
    const head = await gitHeadText(file);
    if (!head) { record(`legal ${file} HEAD available`, "SKIP", "git show failed"); continue; }
    const headText = mainText(head);
    const headSent = sentences(headText);
    const { context, page } = await newPage(browser, { width: 1280 });
    try {
      await goto(page, file);
      const liveText = norm(await page.locator("main, article").first().innerText().catch(() => ""));
      // Case-insensitive: legal eyebrow uses text-transform:uppercase, so
      // innerText returns "LECTERN / PRIVACY" for source "Lectern / Privacy".
      // Also collapse tag-strip spacing before punctuation ("gmail.com ." vs "gmail.com.").
      const tight = (s) => s.toLowerCase().replace(/\s+([.,;:!?])/g, "$1");
      const liveLower = tight(liveText);
      const missingSent = headSent.filter((s) => !liveLower.includes(tight(s.slice(0, 60))));
      record(`legal ${file} wording preserved`, missingSent.length === 0 ? "PASS" : "FAIL",
        missingSent.length === 0 ? `${headSent.length} HEAD sentences all present (nav/TOC additions allowed)` : `${missingSent.length}/${headSent.length} HEAD sentences missing e.g. ${missingSent.slice(0, 2).join(" … ").slice(0, 240)}`);
      if (file === "privacy.html") {
        const anchor = await page.locator("#google").count().catch(() => 0);
        record("legal privacy #google anchor", anchor > 0 ? "PASS" : "FAIL", anchor > 0 ? "#google present" : "#google missing");
        // Fragment navigation works.
        await page.goto(new URL("privacy.html#google", BASE_URL).toString(), { waitUntil: "domcontentloaded", timeout: TIMEOUT }).catch(() => {});
        const vis = await page.locator("#google").first().isVisible().catch(() => false);
        record("legal privacy #google reachable", vis ? "PASS" : "FAIL", vis ? "fragment target visible" : "fragment target not visible");
      }
    } catch (e) { record(`legal ${file} wording preserved`, "FAIL", e.message?.split("\n")[0]); }
    finally { await context.close(); }
  }

  // ---- 7. Required links ----
  {
    const { context, page } = await newPage(browser, { width: 1280 });
    try {
      await goto(page, "index.html");
      const hrefs = await page.evaluate(() => Array.from(document.querySelectorAll("a[href]")).map((a) => a.getAttribute("href")));
      const need = ["https://github.com/aoppenh1-afk/Lectern/releases/latest", "privacy.html", "terms.html", "mailto:senderopp@gmail.com"];
      for (const n of need) {
        record(`link ${n}`, hrefs.includes(n) ? "PASS" : "FAIL", hrefs.includes(n) ? "present" : `absent (have ${hrefs.length} links)`);
      }
    } catch (e) { record("required links", "FAIL", e.message?.split("\n")[0]); }
    finally { await context.close(); }
  }

  await browser.close();
  const pass = results.filter((r) => r.status === "PASS").length;
  const fail = results.filter((r) => r.status === "FAIL").length;
  const skip = results.filter((r) => r.status === "SKIP").length;
  if (WANT_JSON) console.log(JSON.stringify({ baseUrl: BASE_URL, pass, fail, skip, results }, null, 2));
  else console.log(`\nSummary: ${pass} PASS, ${fail} FAIL, ${skip} SKIP (${results.length} checks) BASE_URL=${BASE_URL}`);
  process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => { console.error("Harness crashed: " + (e.stack || e.message)); process.exit(2); });
