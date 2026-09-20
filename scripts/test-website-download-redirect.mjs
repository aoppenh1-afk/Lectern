import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const source = await readFile(path.join(root, 'assets', 'download.js'), 'utf8');
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

function makeStorage(initial = {}) {
  const data = { ...initial };
  return {
    getItem: (key) => (key in data ? data[key] : null),
    setItem: (key, value) => { data[key] = String(value); },
    removeItem: (key) => { delete data[key]; },
    data,
  };
}

function makeLink(href) {
  return { href, listeners: {}, addEventListener(event, fn) { (this.listeners[event] ??= []).push(fn); } };
}

async function loadDownloadJs(pageUrl) {
  const appended = [];
  const body = makeElement();
  body.appendChild = (child) => { appended.push(child); return child; };
  const links = [makeLink('fallback'), makeLink('fallback')];
  const document = {
    querySelectorAll: () => links,
    createElement: () => makeElement(),
    body,
    activeElement: null,
    addEventListener: () => {},
  };
  const sessionStorage = makeStorage();
  const window = { location: { href: pageUrl }, sessionStorage };
  const fetch = async () => ({
    ok: true,
    json: async () => ({ assets: [{ name: 'Lectern-2.6.1.dmg', browser_download_url: DMG }] }),
  });
  await new AsyncFunction('document', 'fetch', 'window', source)(document, fetch, window);
  return { appended, links, window, document, sessionStorage };
}

function click(link, event = {}) {
  const full = { button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, preventDefault() { this.defaultPrevented = true; }, ...event };
  for (const fn of link.listeners.click ?? []) fn(full);
  return full;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Plain left click off the guide: hands the URL over and navigates at once.
{
  const { appended, links, window, sessionStorage } = await loadDownloadJs('https://example.com/index.html');
  assert.equal(links[0].href, DMG);
  const event = click(links[0]);
  assert.equal(event.defaultPrevented, true);
  assert.equal(sessionStorage.data['lectern-dmg-url'], DMG);
  assert.equal(window.location.href, 'downloads.html');
  assert.equal(appended.filter((el) => el.src === DMG).length, 0);
}

// Install guide: download fires here, modal shows, no navigation.
{
  const { appended, links, window } = await loadDownloadJs('https://example.com/install.html');
  const event = click(links[0]);
  assert.equal(event.defaultPrevented, true);
  assert.ok(appended.some((el) => el.src === DMG));
  await sleep(400);
  const backdrop = appended.find((el) => el.className === 'dl-backdrop');
  assert.equal(backdrop.hidden, false);
  assert.equal(window.location.href, 'https://example.com/install.html');
}

// Film page clicks: download fires here, no redirect loop.
{
  const { appended, links, window } = await loadDownloadJs('https://example.com/downloads.html');
  click(links[0]);
  assert.ok(appended.some((el) => el.src === DMG));
  await sleep(100);
  assert.equal(window.location.href, 'https://example.com/downloads.html');
}

// Modified click (cmd-click): browser default untouched.
{
  const { appended, links, window } = await loadDownloadJs('https://example.com/index.html');
  const before = appended.length;
  const event = click(links[0], { metaKey: true });
  assert.notEqual(event.defaultPrevented, true);
  assert.equal(appended.length, before);
  assert.equal(window.location.href, 'https://example.com/index.html');
}

// Film page boot with a handed-over URL: download starts on load.
{
  const film = await readFile(path.join(root, 'downloads.html'), 'utf8');
  const scripts = [...film.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  assert.ok(scripts.length > 0);
  for (const script of scripts) {
    const appended = [];
    const body = makeElement();
    body.appendChild = (child) => { appended.push(child); return child; };
    const document = { createElement: () => makeElement(), body };
    const window = { sessionStorage: makeStorage({ 'lectern-dmg-url': DMG }) };
    const fetch = async () => { throw new Error('must not fetch when handed a URL'); };
    await new AsyncFunction('document', 'fetch', 'window', script)(document, fetch, window);
    await sleep(50);
    assert.ok(appended.some((el) => el.src === DMG));
  }
}

// Film page boot as a direct visit: resolves the latest release itself.
{
  const film = await readFile(path.join(root, 'downloads.html'), 'utf8');
  const script = [...film.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');
  const appended = [];
  const body = makeElement();
  body.appendChild = (child) => { appended.push(child); return child; };
  const document = { createElement: () => makeElement(), body };
  const window = { sessionStorage: makeStorage() };
  const fetch = async () => ({
    ok: true,
    json: async () => ({ assets: [{ name: 'Lectern-2.6.1.dmg', browser_download_url: DMG }] }),
  });
  await new AsyncFunction('document', 'fetch', 'window', script)(document, fetch, window);
  await sleep(50);
  assert.ok(appended.some((el) => el.src === DMG));
}

console.log('PASS: instant film redirect with handover; guide modal, film boot, and modified-click behavior preserved.');
