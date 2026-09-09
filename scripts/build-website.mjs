// Assemble the static site without including the native app or repository files.
import { cp, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = path.join(root, '.vercel-site');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const file of ['index.html', 'install.html', 'privacy.html', 'terms.html', 'style.css', 'icon.png', 'assets']) {
  await cp(path.join(root, file), path.join(output, file), { recursive: true });
}
console.log('Website ready in .vercel-site');
