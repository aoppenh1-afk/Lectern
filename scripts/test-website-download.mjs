import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../assets/download.js', import.meta.url), 'utf8');
const run = new (Object.getPrototypeOf(async function(){}).constructor)('document', 'fetch', source);
const base = 'https://github.com/aoppenh1-afk/Lectern/releases/download/v3/';
const asset = name => ({ name, browser_download_url: base + name });
async function resolve(assets, ok = true) {
  const links = [{ href: 'fallback' }, { href: 'fallback' }];
  await run({ querySelectorAll: () => links }, async () => ({ ok, json: async () => ({ assets }) }));
  assert.equal(links[0].href, links[1].href);
  return links[0].href;
}
assert.equal(await resolve([asset('Lectern-3.zip'), asset('Lectern-3.dmg')]), base+'Lectern-3.dmg');
assert.equal(await resolve([asset('Lectern-3.zip')]), base+'Lectern-3.zip');
assert.equal(await resolve([]), 'fallback');
assert.equal(await resolve([], false), 'fallback');
assert.equal(await resolve([{ name:'Lectern-3.dmg', browser_download_url:'https://example.com/installer.dmg' }]), 'fallback');
assert.equal(await resolve([asset('Lectern-3.dmg.sha256'), asset('Lectern-3.zip')]), base+'Lectern-3.zip');
console.log('PASS: DMG preferred, ZIP compatibility, checksum exclusion, safe URL validation, and offline fallback.');
