// assets/story.js — scroll previews + Guided tour / Explore UI.
// Demo contract: setMode never renders; showStep always paints tour;
// demo clicks adopt visible tour then render explored.
const STEP_NAMES = ["overview","capture","transcript","notes","flashcards","quiz","docs"];
const isStep = (v) => typeof v === "string" && STEP_NAMES.includes(v);
const stepOf = (el) => isStep(el?.getAttribute?.("data-demo-step")) ? el.getAttribute("data-demo-step")
  : isStep(el?.getAttribute?.("data-story-step")) ? el.getAttribute("data-story-step") : null;
const stage = document.getElementById("demo") ?? document.querySelector(".demo-stage");
const root = document.getElementById("lectern-demo");
const chapters = [...document.querySelectorAll("[data-story-step]")];
const modeLabels = [...document.querySelectorAll("[data-demo-mode]")];
const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
let demo = null;
let demoReady = false;
let mode = "tour";
let selected = stepOf(chapters[0]) ?? "overview";
let pending = selected;
let focusedInside = false;
let reducedMotion = motionQuery.matches;
let expandTrigger = null;
let navSeq = 0;
function syncUI() {
  for (const label of modeLabels) label.textContent = mode === "explore" ? "Explore the app" : "Guided tour";
  const expanded = !!stage?.classList.contains("demo-expanded");
  for (const button of document.querySelectorAll("[data-demo-action]")) {
    const action = button.getAttribute("data-demo-action");
    if (action === "explore") button.hidden = mode !== "tour";
    else if (action === "resume") button.hidden = mode !== "explore";
    else if (action === "expand") {
      button.setAttribute("aria-expanded", String(expanded));
      button.textContent = expanded ? "Close expanded view" : "Expand demo";
    }
  }
}
function updateCaption(step) {
  const chapter = chapters.find((c) => stepOf(c) === step);
  if (!chapter) return;
  const fields = [["[data-story-caption]", "h3"], ["[data-story-description]", "h3 + p"], ["[data-story-count]", ".number"]];
  for (const [target, source] of fields) {
    for (const hook of document.querySelectorAll(target)) hook.textContent = chapter.querySelector(source)?.textContent ?? "";
  }
  stage?.setAttribute("data-current-step", step);
  document.querySelector(".tour")?.style.setProperty("--chapter", String(STEP_NAMES.indexOf(step)));
  if (!reducedMotion) document.querySelector(".story-caption")?.animate?.(
    [{ opacity: .4, transform: "translateY(5px)" }, { opacity: 1, transform: "translateY(0)" }],
    { duration: 260, easing: "ease-out" }
  );
}
function markCurrent(step) {
  selected = step;
  for (const chapter of chapters) {
    if (stepOf(chapter) === step) chapter.setAttribute("aria-current", "true");
    else chapter.removeAttribute("aria-current");
  }
  for (const button of document.querySelectorAll("[data-demo-step]")) {
    button.setAttribute("aria-pressed", String(stepOf(button) === step));
  }
  updateCaption(step);
}
function onScrollChapter(step) {
  pending = step;
  if (!demoReady || reducedMotion || stage?.classList.contains("demo-expanded")) return;
  mode = "tour";
  demo?.setMode("tour");
  syncUI();
  if (step !== selected) markCurrent(step);
  demo?.showStep(step);
}
// Explicit preview is manual intent: show step, adopt it, enter explore
// until the next scroll chapter takes over.
function previewRequest(step) {
  navSeq++;
  pending = step;
  demo?.showStep(step);
  demo?.setMode("explore");
  mode = "explore";
  markCurrent(step);
  syncUI();
}
function enterExplore(explicit) {
  if (mode === "explore") return;
  navSeq++;
  mode = "explore";
  if (explicit) demo?.setMode("explore");
  syncUI();
}
// Explicit Resume tour renders last observed scroll position.
function resumeTour() {
  navSeq++;
  mode = "tour";
  demo?.setMode("tour");
  demo?.showStep(pending);
  markCurrent(pending);
  syncUI();
}
function resetDemo() {
  navSeq++;
  demo?.reset();
  mode = "tour";
  pending = "overview";
  markCurrent("overview");
  syncUI();
}
function setExpanded(expanded, trigger) {
  if (!stage) return;
  // In-page CSS (position:relative), not a fixed overlay: no dialog/trap.
  // If art switches to fixed overlay, parent must add modal semantics.
  stage.classList.toggle("demo-expanded", expanded);
  if (trigger instanceof HTMLElement) expandTrigger = trigger;
  syncUI();
  if (!expanded) expandTrigger?.focus({ preventScroll: true });
}
function scrollToDemo(focusApp) {
  const my = ++navSeq;
  (stage ?? root)?.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth", block: "start" });
  if (!focusApp || !root) return;
  const focusEl = root.querySelector("[data-demo-focus]") ??
    root.querySelector("h2, h3, button, [href], input, select, [tabindex]");
  if (!(focusEl instanceof HTMLElement)) return;
  if (!focusEl.hasAttribute("tabindex") && /^H[1-4]$/.test(focusEl.tagName)) focusEl.tabIndex = -1;
  setTimeout(() => { if (my === navSeq) focusEl.focus({ preventScroll: true }); }, reducedMotion ? 0 : 350);
}
// One scroll calculation selects the chapter, including fast scrolls and jumps.
// Small screens and reduced-motion users navigate with the explicit step buttons.
const cinematicQuery = window.matchMedia("(min-width: 761px)");
let scrollFrame = 0;
function focusScale(top, remaining, height, viewport) {
  const smooth = value => { const x=Math.max(0,Math.min(1,value)); return x*x*(3-2*x); };
  const entrance=smooth((viewport*.65-top)/Math.max(1,viewport*.65-100));
  const exit=smooth((remaining-height-100)/(viewport*.55));
  return 1+.15*Math.min(entrance,exit);
}
function trackStory() {
  scrollFrame = 0;
  const tour = document.querySelector(".tour");
  if(tour) document.body.classList.toggle("past-classroom",tour.getBoundingClientRect().bottom<80);
  if (!demoReady || !cinematicQuery.matches || reducedMotion) {
    stage?.style.setProperty('--focus-scale','1');
    return;
  }
  const product=document.querySelector('.tour-product');
  if(tour && product && !stage?.classList.contains('demo-expanded')) {
    stage?.style.setProperty('--focus-scale',String(focusScale(product.getBoundingClientRect().top,tour.getBoundingClientRect().bottom,product.offsetHeight,window.innerHeight)));
  }
  const rail = document.querySelector(".chapter-rail");
  if (!tour || !rail) return;
  const intro=document.querySelector(".scene-intro");
  const travelled = Math.max(0, -tour.getBoundingClientRect().top - (intro?.offsetHeight || 0) + 100);
  document.body.classList.toggle("past-classroom",tour.getBoundingClientRect().bottom<80);

  const chapterHeight = window.innerHeight * .75;
  const index = Math.min(STEP_NAMES.length - 1, Math.floor(travelled / chapterHeight));
  const step = STEP_NAMES[index];
  if (step !== pending) onScrollChapter(step);
}
function queueStory() {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(trackStory);
}
window.addEventListener("scroll", queueStory, { passive: true });
// The laptop occupies most of the scene. Wheel input over it must still turn
// the story pages; expanded view keeps normal scrolling inside app panels.
root?.addEventListener("wheel", (event) => {
  if (!cinematicQuery.matches || reducedMotion || stage?.classList.contains("demo-expanded") || event.ctrlKey || Math.abs(event.deltaX)>Math.abs(event.deltaY)) return;
  event.preventDefault();
  const delta=event.deltaY*(event.deltaMode===1?16:event.deltaMode===2?window.innerHeight:1);
  window.scrollBy({top:delta,behavior:"instant"});
}, {passive:false});
window.addEventListener("resize", queueStory, { passive: true });
markCurrent(selected);
syncUI();
root?.addEventListener("lectern:interact", () => enterExplore(false), { passive: true });
root?.addEventListener("focusin", () => { focusedInside = true; });
root?.addEventListener("focusout", (event) => {
  if (!(event.relatedTarget instanceof Node && root.contains(event.relatedTarget))) focusedInside = false;
});
document.addEventListener("click", (event) => {
  if (!(event.target instanceof Element)) return;
  const actionEl = event.target.closest("[data-demo-action]");
  if (actionEl) {
    const action = actionEl.getAttribute("data-demo-action");
    if (action === "explore") {
      enterExplore(true);
      setExpanded(true, actionEl);
      document.querySelector('[data-demo-action="resume"]')?.focus();
    } else if (action === "resume") {
      setExpanded(false);
      resumeTour();
      document.querySelector('[data-demo-action="explore"]')?.focus();
    } else if (action === "reset") resetDemo();
    else if (action === "expand") setExpanded(!stage?.classList.contains("demo-expanded"), actionEl);
    else if (action === "try") scrollToDemo(true);
    return;
  }
  const anchor = event.target.closest('a[href="#demo"]');
  if (anchor) { event.preventDefault(); scrollToDemo(true); return; }
  const stepEl = event.target.closest("[data-demo-step]");
  const step = stepEl ? stepOf(stepEl) : null;
  if (step) previewRequest(step);
});
// Passive article clicks preview on tour only; step buttons work always.
for (const chapter of chapters) {
  chapter.addEventListener("click", (event) => {
    if (event.target instanceof Element && event.target.closest("[data-demo-step], a, button")) return;
    const step = stepOf(chapter);
    if (step && mode === "tour") previewRequest(step);
  });
}
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && stage?.classList.contains("demo-expanded")) setExpanded(false);
});
motionQuery.addEventListener?.("change", (event) => { reducedMotion = event.matches; });
const demoModule = await import("./demo.js").catch(() => null);
if (root && typeof demoModule?.mountDemo === "function") demo = demoModule.mountDemo(root);
demoReady = !!demo;
if (demoReady) {
  document.documentElement.classList.add("story-enabled");
  for (const chapter of chapters) chapter.setAttribute("aria-hidden", "true");
  queueStory();
}
pending = selected;

// Fit the complete desktop canvas into the laptop without reflowing native columns.
const appViewport = document.querySelector('.app-viewport');
function fitNativeCanvas() {
  const desktop = window.innerWidth > 760;
  document.documentElement.classList.toggle('desktop-demo', desktop);
  if (appViewport && root) root.style.setProperty('--app-scale', String(appViewport.clientWidth / 1470));
}
fitNativeCanvas();
if (appViewport && 'ResizeObserver' in window) new ResizeObserver(fitNativeCanvas).observe(appViewport);
window.addEventListener('resize', fitNativeCanvas, { passive: true });
