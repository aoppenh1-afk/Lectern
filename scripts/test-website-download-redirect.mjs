import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../assets/download.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

const DMG = 'https://github.com/aoppenh1-afk/Lectern/releases/download/v2.6.1/Lectern-2.6.1.dmg';

function makeElement() {
  return {
    children: [],
    attributes: {},
    style: {},
    hidden: false,
    className: '',
    innerHTML: '',
    src: '',
    listeners: {},
    appendChild(child) { this.children.push(child); return child; },
    addEventListener(event, fn) { (this.listeners[event] ??= []).push(fn); },
    querySelector() { return makeElement(); },
    setAttribute(key, value) { this.attributes[key] = value; },
    focus() {},
  };
}

function makeLink(href) {
  return { href, listeners: {}, addEventListener(event, fn) { (this.listeners[event] ??= []).push(fn); } };
}

async function loadOn(pageUrl) {
  const appended = [];
  const body = makeElement();
  body.appendChild = (child) => { appended.push(child); return child; };
  const listeners = {};
  const document = {
    querySelectorAll: () => links,
    createElement: () => makeElement(),
    body,
    activeElement: null,
    addEventListener: (event, fn) => { (listeners[event] ??= []).push(fn); },
  };
  const links = [makeLink('fallback'), makeLink('fallback')];
  // querySelectorAll above closes over `links` declared after; rebind:
  document.querySelectorAll = () => links;
  const window = { location: { href: pageUrl } };
  const fetch = async () => ({
    ok: true,
    json: async () => ({ assets: [{ name: 'Lectern-2.6.1.dmg', browser_download_url: DMG }] }),
  });
  const run = new AsyncFunction('document', 'fetch', 'window', source);
  await run(document, fetch, window);
  return { appended, links, window, document };
}

function click(link, event = {}) {
  const full = { button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, preventDefault() { this.defaultPrevented = true; }, ...event };
  for (const fn of link.listeners.click ?? []) fn(full);
  return full;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Plain left click on the homepage: download fires via iframe, tab redirects.
{
  const { appended, links, window } = await loadOn('https://example.com/index.html');
  assert.equal(links[0].href, DMG);
  const event = click(links[0]);
  assert.equal(event.defaultPrevented, true);
  const frames = appended.filter((el) => el.src === DMG);
  assert.equal(frames.length, 1);
  await sleep(750);
  assert.equal(window.location.href, 'downloads.html');
}

// Install guide: download fires, modal shows, no navigation.
{
  const { appended, links, window, document } = await loadOn('https://example.com/install.html');
  const event = click(links[0]);
  assert.equal(event.defaultPrevented, true);
  assert.ok(appended.some((el) => el.src === DMG));
  await sleep(400);
  const backdrop = appended.find((el) => el.className === 'dl-backdrop');
  assert.equal(backdrop.hidden, false);
  assert.equal(window.location.href, 'https://example.com/install.html');
  assert.ok(document.body.style.overflow === 'hidden');
}

// Film page: download fires, no redirect loop.
{
  const { appended, links, window } = await loadOn('https://example.com/downloads.html');
  click(links[0]);
  assert.ok(appended.some((el) => el.src === DMG));
  await sleep(750);
  assert.equal(window.location.href, 'https://example.com/downloads.html');
}

// Modified click (cmd-click): browser default untouched, no redirect.
{
  const { appended, links, window } = await loadOn('https://example.com/index.html');
  const before = appended.length;
  const event = click(links[0], { metaKey: true });
  assert.notEqual(event.defaultPrevented, true);
  assert.equal(appended.length, before);
  await sleep(750);
  assert.equal(window.location.href, 'https://example.com/index.html');
}

console.log('PASS: iframe download survives the film redirect; modal, film-page, and modified-click behavior preserved.');
