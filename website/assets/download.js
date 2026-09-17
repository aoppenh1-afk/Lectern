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

// Post-download Gatekeeper help: the app is not signed with an Apple Developer
// ID, so macOS blocks the first open. Let the download proceed, then show a
// modal pointing at install.html#open. Guarded so the release-resolution test
// (minimal document mock) and no-JS fallback keep working.
try {
  const canRender =
    typeof document !== 'undefined' &&
    typeof document.createElement === 'function' &&
    document.body &&
    typeof document.body.appendChild === 'function';
  if (canRender && links.length > 0) {
    const backdrop = document.createElement('div');
    backdrop.className = 'dl-backdrop';
    backdrop.hidden = true;
    backdrop.innerHTML =
      '<div class="dl-modal" role="dialog" aria-modal="true" aria-labelledby="dl-modal-title">' +
      '<p class="eyebrow">Download started</p>' +
      '<h2 id="dl-modal-title">One extra step on first open</h2>' +
      '<p>Lectern isn&rsquo;t signed with an Apple Developer ID, so macOS will block the first open ' +
      'with a message like &ldquo;Lectern can&rsquo;t be opened&rdquo; or &ldquo;was blocked to protect your Mac&rdquo;. ' +
      'That warning is expected. Your download continues in the background.</p>' +
      '<ol>' +
      '<li>Open the DMG and drag <strong>Lectern</strong> into <strong>Applications</strong>.</li>' +
      '<li>Double-click Lectern in Applications, then dismiss the warning.</li>' +
      '<li>Open <strong>System Settings &rarr; Privacy &amp; Security</strong> and click <strong>Open Anyway</strong>.</li>' +
      '</ol>' +
      '<div class="dl-actions">' +
      '<a class="button" href="install.html#open">Open installation guide</a>' +
      '<button type="button" class="button-secondary dl-close">Got it</button>' +
      '</div>' +
      '<p class="meta">Only approve copies you downloaded from Lectern&rsquo;s official releases.</p>' +
      '<button type="button" class="dl-x" aria-label="Close dialog">&times;</button>' +
      '</div>';
    document.body.appendChild(backdrop);
    const dialog = backdrop.querySelector('.dl-modal');
    const closeBtn = backdrop.querySelector('.dl-close');
    const xBtn = backdrop.querySelector('.dl-x');
    let lastFocused = null;
    const show = () => {
      lastFocused = document.activeElement;
      backdrop.hidden = false;
      document.body.style.overflow = 'hidden';
      (closeBtn || dialog).focus?.();
    };
    const hide = () => {
      backdrop.hidden = true;
      document.body.style.overflow = '';
      lastFocused?.focus?.();
    };
    closeBtn?.addEventListener('click', hide);
    xBtn?.addEventListener('click', hide);
    backdrop.addEventListener('click', (event) => {
      if (event.target === backdrop) hide();
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && !backdrop.hidden) hide();
    });
    for (const link of links) {
      link.addEventListener('click', () => {
        // Let the browser start the download first, then explain the warning.
        setTimeout(show, 250);
      });
    }
  }
} catch {
  // Modal is progressive enhancement; the direct DMG link still works.
}
