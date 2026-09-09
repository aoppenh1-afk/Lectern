// Release filenames include a version, so resolve the installer from the latest release.
// The HTML already contains a verified DMG link for immediate clicks and no-JS use.
const links = [...document.querySelectorAll('[data-mac-download]')];
try {
  const response = await fetch('https://api.github.com/repos/aoppenh1-afk/Lectern/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' },
    signal: AbortSignal.timeout(6000)
  });
  if (!response.ok) throw new Error('Release lookup unavailable');
  const release = await response.json();
  const asset = release.assets?.find(a => /^Lectern(?:-[\w.-]+)?\.dmg$/i.test(a.name))
    ?? release.assets?.find(a => /^Lectern(?:-[\w.-]+)?\.zip$/i.test(a.name));
  const url = new URL(asset?.browser_download_url);
  if (url.origin !== 'https://github.com' || !url.pathname.startsWith('/aoppenh1-afk/Lectern/releases/download/') || ! /\.(dmg|zip)$/i.test(url.pathname)) throw new Error('Unexpected release asset');
  for (const link of links) link.href = url.href;
} catch {
  // If GitHub cannot be reached, retain the verified installer from the last site update.
}
