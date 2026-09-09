#!/usr/bin/env node
// Portable interaction checks. Owns ONLY this file. No repo installs.
// Env: BASE_URL, PLAYWRIGHT_MODULE (file path or bare specifier),
//   PLAYWRIGHT_CHANNEL / BROWSER_CHANNEL (default "chrome"),
//   PLAYWRIGHT_EXECUTABLE / CHROME_EXECUTABLE (optional override), HEADLESS.
const BASE = (process.env.BASE_URL || "http://127.0.0.1:8765/Lectern/").replace(/\/?$/, "/");
const CHANNEL = process.env.PLAYWRIGHT_CHANNEL || process.env.BROWSER_CHANNEL || "chrome";
const EXEC = process.env.PLAYWRIGHT_EXECUTABLE || process.env.CHROME_EXECUTABLE || process.env.CHROME_PATH || undefined;
const HEADLESS = !/^(0|false|no)$/i.test(process.env.HEADLESS ?? "1");
const results = [];
function rec(name, ok, detail = "") {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? " — " + detail : ""}`);
}
async function loadPW() {
  const seen = new Set();
  const cands = [process.env.PLAYWRIGHT_MODULE, "playwright", "playwright-core"].filter(Boolean).filter((s) => !seen.has(s) && seen.add(s));
  let last = null;
  for (const spec of cands) {
    try { return (await import(spec)).chromium; } catch (e) { last = e; }
  }
  throw new Error("playwright load failed (set PLAYWRIGHT_MODULE): " + (last?.message || "unknown"));
}
async function launch(chromium) {
  const opts = { headless: HEADLESS };
  if (EXEC) return chromium.launch({ ...opts, executablePath: EXEC });
  if (CHANNEL) {
    try { return await chromium.launch({ ...opts, channel: CHANNEL }); }
    catch { return await chromium.launch({ ...opts }); }
  }
  return chromium.launch(opts);
}
async function newPage(browser, o = {}) {
  const ctx = await browser.newContext({
    viewport: { width: o.w || 1280, height: o.h || 900 },
    ...(o.js === false ? { javaScriptEnabled: false } : {}),
    ...(o.rm ? { reducedMotion: "reduce" } : {}),
  });
  return { ctx, page: await ctx.newPage() };
}
async function goto(page) {
  await page.goto(new URL("index.html", BASE).toString(), { waitUntil: "domcontentloaded", timeout: 15000 });
  await page.waitForSelector("#lectern-demo", { timeout: 8000 });
  await page.waitForTimeout(600);
}
async function openMemory(page) {
  await page.click('#lectern-demo [data-act="nav"][data-id="courses"]', { timeout: 4000 });
  await page.waitForSelector('#lectern-demo [data-act="open-lecture"][data-id="l-memory"]', { timeout: 4000 });
  await page.click('#lectern-demo [data-act="open-lecture"][data-id="l-memory"]', { timeout: 4000 });
  await page.waitForSelector('#lectern-demo [data-act="tab"][data-id="transcript"]', { timeout: 4000 });
  await page.waitForTimeout(300);
}
async function toTab(page, id) {
  await page.click(`#lectern-demo [data-act="tab"][data-id="${id}"]`, { timeout: 4000 });
  await page.waitForTimeout(350);
}
const txt = (page, sel) => page.locator(sel).first().innerText({ timeout: 4000 });
const mode = (page) => txt(page, "[data-demo-mode]");
async function run(name, browser, fn, opts) {
  const { ctx, page } = await newPage(browser, opts);
  try { await fn(page); } catch (e) { rec(name, false, String(e.message || e).split("\n")[0]); }
  finally { await ctx.close(); }
}
async function main() {
  const browser = await launch(await loadPW());
  await run("initial overview", browser, async (page) => {
    await goto(page);
    const t = await txt(page, "#lectern-demo");
    const ok = t.includes("Today\u2019s Command Studio") && t.includes("Sample demo. No recording or uploads.");
    rec("initial overview", ok, t.slice(0, 100).replace(/\s+/g, " "));
    if (!ok) throw new Error("overview mismatch");
  });
  await run("courses+memory", browser, async (page) => {
    await goto(page);
    await page.click('#lectern-demo [data-act="nav"][data-id="courses"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const t1 = await txt(page, "#lectern-demo");
    if (!t1.includes("Courses") || !t1.includes("How memory forms")) throw new Error("FIRST Courses click missed: " + t1.slice(0, 150));
    rec("first courses click", true, "course list visible");
    await page.click('#lectern-demo [data-act="open-lecture"][data-id="l-memory"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const t2 = await txt(page, "#lectern-demo");
    if (!t2.includes("How memory forms")) throw new Error("open memory failed");
    rec("select memory lecture", true, "lecture header present");
  });
  await run("notes outline", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "notes");
    const t = await txt(page, "#lectern-demo");
    const ok = t.includes("Encoding: getting it in") && t.includes("Retrieval practice (self-test) beats rereading.");
    rec("notes outline", ok, ok ? "exact outline strings present" : t.slice(0, 300));
    if (!ok) throw new Error("notes exact text missing");
  });
  await run("cards reveal exact", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "cards");
    const before = await txt(page, "#lectern-demo");
    const back = "Encoding, storage, retrieval. A failure at any stage breaks recall.";
    if (before.includes(back)) throw new Error("answer visible before reveal");
    if (!before.includes("Name the three stages of memory formation.")) throw new Error("card front missing");
    await page.click('#lectern-demo [data-act="flip"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const after = await txt(page, "#lectern-demo");
    const btn = await txt(page, '#lectern-demo [data-act="flip"]');
    const pressed = await page.getAttribute('#lectern-demo [data-act="flip"]', "aria-pressed");
    const ok = after.includes(back) && btn.includes("Hide answer") && pressed === "true";
    rec("cards reveal exact", ok, ok ? "before hidden, after exact + Hide answer" : after.slice(0, 300));
    if (!ok) throw new Error("reveal mismatch");
  });
  await run("cards next", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "cards");
    await page.click('#lectern-demo [data-act="next-card"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const t = await txt(page, "#lectern-demo");
    const ok = t.includes("Card 2 of 4") && t.includes("What is elaborative encoding?");
    rec("cards next", ok, ok ? "Card 2 of 4 exact" : t.slice(0, 250));
    if (!ok) throw new Error("next card mismatch");
  });
  await run("quiz exact feedback", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "quiz");
    await page.click('#lectern-demo [data-act="answer"][data-id="q1:0"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const t = await txt(page, "#lectern-demo");
    const ok = t.includes("Correct.") && t.includes("Retrieval practice means recalling without looking.") && t.includes("Score: 1 of 1 answered");
    rec("quiz exact feedback", ok, ok ? "Correct. + explain + score" : t.slice(0, 400));
    if (!ok) throw new Error("quiz feedback mismatch");
  });
  await run("docs twice no duplicates", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "notes");
    await page.click('#lectern-demo [data-act="docs-push"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const f1 = await txt(page, "#lectern-demo");
    if (!f1.includes("Pushed tab")) throw new Error("first push missing: " + f1.slice(0, 200));
    await page.click('#lectern-demo [data-act="docs-push"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const bars = await page.locator("#lectern-demo .ld-docsbar").count();
    const pills = await page.locator('#lectern-demo .ld-docsbar .ld-pill').count();
    const f2 = await txt(page, "#lectern-demo");
    const occ = (f2.match(/Pushed tab/g) || []).length;
    const ok = bars === 1 && pills === 1 && occ === 1 && f2.includes("Pushing again updates the tab.");
    rec("docs twice no duplicates", ok, ok ? "1 docsbar, 1 pill, updates tab" : `bars=${bars} pills=${pills} occ=${occ}`);
    if (!ok) throw new Error(`bars=${bars} pills=${pills} occ=${occ}`);
  });
  await run("capture timer start/stop/reset", browser, async (page) => {
    await goto(page); await openMemory(page);
    const t0 = (await txt(page, "#lectern-demo .ld-timer")).trim();
    if (t0 !== "00:00") throw new Error("initial timer not 00:00 got " + t0);
    await page.click('#lectern-demo [data-act="rec-start"]', { timeout: 4000 });
    await page.waitForTimeout(2200);
    const t1 = (await txt(page, "#lectern-demo .ld-timer")).trim();
    if (t1 === "00:00") throw new Error("timer did not advance");
    await page.click('#lectern-demo [data-act="rec-stop"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const ts = await txt(page, "#lectern-demo");
    if (!ts.includes("Sample saved. Transcription is simulated.")) throw new Error("stop did not save");
    await page.click('#lectern-demo [data-act="rec-reset"]', { timeout: 4000 });
    await page.waitForTimeout(350);
    const t2 = (await txt(page, "#lectern-demo .ld-timer")).trim();
    const te = await txt(page, "#lectern-demo");
    const ok = t2 === "00:00" && te.includes("Simulated capture.");
    rec("capture timer start/stop/reset", ok, `00:00->${t1}->saved->${t2}`);
    if (!ok) throw new Error("reset mismatch " + t2);
  });
  await run("click-then-scroll retains", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "notes");
    const sel = await page.getAttribute('#lectern-demo [data-act="tab"][data-id="notes"]', "aria-selected");
    const before = await txt(page, "#lectern-demo");
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(600);
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(600);
    const sel2 = await page.getAttribute('#lectern-demo [data-act="tab"][data-id="notes"]', "aria-selected");
    const after = await txt(page, "#lectern-demo");
    const ok = sel === "true" && sel2 === "true" && before === after;
    rec("click-then-scroll retains", ok, ok ? "notes tab still selected, text identical" : `sel ${sel}->${sel2}`);
    if (!ok) throw new Error("scroll changed selection");
  });
  await run("focus meaningful", browser, async (page) => {
    await goto(page); await openMemory(page); await toTab(page, "quiz");
    const info = await page.evaluate(() => {
      const a = document.activeElement;
      const inside = !!a?.closest?.("#lectern-demo");
      return { tag: a?.tagName, key: a?.getAttribute?.("data-fkey"), inside, text: (a?.textContent || "").trim().slice(0, 50) };
    });
    const head = await page.evaluate(() => {
      const h = document.querySelector("#lectern-demo .ld-content h2");
      return h ? { text: h.textContent.slice(0, 40), tab: h.getAttribute("tabindex") } : null;
    });
    const ok = info.inside && info.tag !== "BODY" && !!head;
    rec("focus meaningful", ok, `${info.tag} key=${info.key} inside=${info.inside} "${info.text}" head=${head?.text}@${head?.tab}`);
    if (!ok) throw new Error("focus not meaningful " + JSON.stringify(info));
  });
  for (const w of [390, 320]) {
    await run(`mobile ${w}px select->courses`, browser, async (page) => {
      await goto(page);
      await page.selectOption("#lectern-demo #ld-navsel", "courses", { timeout: 4000 });
      await page.waitForTimeout(400);
      const t = await txt(page, "#lectern-demo");
      const sel = await page.$eval("#lectern-demo #ld-navsel", (el) => el.value);
      const ok = sel === "courses" && t.includes("Courses");
      rec(`mobile ${w}px select->courses`, ok, ok ? "select navigation works" : t.slice(0, 200));
      if (!ok) throw new Error("mobile nav failed");
    }, { w, h: 844 });
  }
  // ---- new regressions (fail, never skip, on missing controls) ----
  await run("preview from explore", browser, async (page) => {
    await goto(page);
    await page.click('[data-demo-action="explore"]', { timeout: 4000 });
    await page.waitForTimeout(300);
    await page.click('[data-demo-step="notes"]', { timeout: 4000 });
    await page.waitForTimeout(400);
    const t = await txt(page, "#lectern-demo");
    const m = await mode(page);
    const ok = t.includes("Encoding: getting it in") && m.includes("Guided tour");
    rec("preview from explore -> notes", ok, ok ? "explore preview lands on notes, back to tour" : `${m} | ${t.slice(0, 160)}`);
    if (!ok) throw new Error("explore preview missed notes screen");
  });
  await run("resume tour", browser, async (page) => {
    await goto(page);
    await page.click('[data-demo-action="explore"]', { timeout: 4000 });
    await page.waitForTimeout(300);
    await page.click('[data-demo-action="resume"]', { timeout: 4000 });
    await page.waitForTimeout(400);
    const t = await txt(page, "#lectern-demo");
    const m = await mode(page);
    const ok = m.includes("Guided tour") && t.includes("Today\u2019s Command Studio");
    rec("resume tour", ok, ok ? "resume returns to guided overview" : `${m} | ${t.slice(0, 160)}`);
    if (!ok) throw new Error("resume did not return to tour overview");
  });
  await run("explore after tour preview", browser, async (page) => {
    await goto(page);
    await page.click('[data-demo-step="flashcards"]', { timeout: 4000 });
    await page.waitForTimeout(400);
    const pre = await txt(page, "#lectern-demo");
    if (!pre.includes("Name the three stages of memory formation.")) throw new Error("tour flashcards preview missed: " + pre.slice(0, 160));
    await page.evaluate(() => document.querySelector('#lectern-demo [data-act="flip"]')?.focus({ preventScroll: true }));
    await page.click('#lectern-demo [data-act="flip"]', { timeout: 4000 });
    await page.waitForTimeout(400);
    const t = await txt(page, "#lectern-demo");
    const m = await mode(page);
    const ok = t.includes("Encoding, storage, retrieval.") && m.includes("Explore the app");
    rec("explore after tour preview card click", ok, ok ? "first card click flips + enters explore" : `${m} | ${t.slice(0, 160)}`);
    if (!ok) throw new Error("card click did not enter explore with answer");
  });
  await run("reset while running", browser, async (page) => {
    await goto(page); await openMemory(page);
    await page.click('#lectern-demo [data-act="rec-start"]', { timeout: 4000 });
    await page.waitForTimeout(1200);
    await page.click('[data-demo-action="reset"]', { timeout: 4000 });
    await page.waitForTimeout(1700);
    const t = (await txt(page, "#lectern-demo .ld-timer")).trim();
    const m = await mode(page);
    const ok = t === "00:00" && m.includes("Guided tour");
    rec("reset while running stops timer", ok, ok ? "00:00 held after reset" : `timer=${t} mode=${m}`);
    if (!ok) throw new Error("timer advanced after reset: " + t);
  });
  await run("keyboard enter preview", browser, async (page) => {
    await goto(page);
    await page.focus('[data-demo-step="notes"]', { timeout: 4000 });
    await page.keyboard.press("Enter");
    await page.waitForTimeout(400);
    const t = await txt(page, "#lectern-demo");
    const ok = t.includes("Encoding: getting it in");
    rec("keyboard enter on chapter preview", ok, ok ? "Enter activates notes preview" : t.slice(0, 160));
    if (!ok) throw new Error("keyboard preview missed notes");
  });
  {
    const { ctx, page } = await newPage(browser, { js: false });
    try {
      await page.goto(new URL("index.html", BASE).toString(), { waitUntil: "domcontentloaded", timeout: 15000 });
      const fb = await page.locator("#lectern-demo .demo-fallback").count();
      const body = await page.locator("#lectern-demo").first().innerText({ timeout: 4000 });
      const dl = await page.locator("a[href*='releases/latest']").count();
      const ok = fb >= 1 && body.includes("How memory forms") && dl >= 1;
      rec("noJS usable fallback", ok, ok ? "static preview + download link usable" : `fallback=${fb} dl=${dl} ${body.slice(0, 120)}`);
      if (!ok) throw new Error("noJS fallback unusable");
    } catch (e) { rec("noJS usable fallback", false, String(e.message || e).split("\n")[0]); }
    finally { await ctx.close(); }
  }
  await run("reduced-motion manual", browser, async (page) => {
    await goto(page);
    const mq = await page.evaluate(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches);
    if (!mq) { rec("reduced-motion manual previews", false, "media query false"); throw new Error("reduced-motion emulation not honored"); }
    else {
      await page.click('[data-demo-step="notes"]', { timeout: 4000 });
      await page.waitForTimeout(400);
      const t1 = await txt(page, "#lectern-demo");
      if (!t1.includes("Encoding: getting it in")) throw new Error("reduced-motion notes preview missed");
      await page.click('[data-demo-step="quiz"]', { timeout: 4000 });
      await page.waitForTimeout(400);
      const t2 = await txt(page, "#lectern-demo");
      const ok = t2.includes("Score:") && t2.includes("Which study action demonstrates retrieval practice?");
      rec("reduced-motion manual previews", ok, ok ? "notes + quiz manual previews work" : t2.slice(0, 160));
      if (!ok) throw new Error("reduced-motion quiz preview missed");
    }
  }, { rm: true });
  await browser.close();
  const p = results.filter((r) => r.ok).length, f = results.filter((r) => !r.ok).length;
  console.log(`\nSummary: ${p} PASS, ${f} FAIL (${results.length} checks) BASE=${BASE}`);
  process.exit(f ? 1 : 0);
}
main().catch((e) => { console.error("crashed: " + (e.stack || e.message)); process.exit(2); });
