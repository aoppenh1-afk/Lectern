// As each step of the real lecture arrives, mark the same idea and draw its chalk arrow, once.
// Everything is fully visible by default, so nothing depends on this running.
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const steps = [...document.querySelectorAll('.af-step')];
if (steps.length && !reduceMotion && 'IntersectionObserver' in window) {
  document.querySelector('.afterword').classList.add('af-motion');
  const stepObserver = new IntersectionObserver(
    entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('is-seen');
        stepObserver.unobserve(entry.target);
      }
    },
    { threshold: 0.4 },
  );
  for (const step of steps) stepObserver.observe(step);
}

// The demo grows the page when it starts, which can be after load, and that throws off a deep link
// such as #download. Jump again after load and again once the demo has taken its full height.
const linked = location.hash ? document.getElementById(decodeURIComponent(location.hash.slice(1))) : null;
if (linked?.closest('.afterword')) {
  const jump = () => requestAnimationFrame(() => linked.scrollIntoView({ behavior: 'instant' }));
  addEventListener('load', jump, { once: true });
  new MutationObserver((_, watcher) => {
    if (!document.documentElement.classList.contains('story-enabled')) return;
    watcher.disconnect();
    jump();
  }).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
}

// Silent demo film autoplays when scrolled into view, pauses when out of view.
const film = document.querySelector('.af-film video');
if (film) {
  film.muted = true; // Required for autoplay policies; the clip has no audio.
  let userPaused = false;
  let inView = false;
  const tryPlay = () => {
    if (reduceMotion || userPaused || !inView || !film.paused) return;
    film.play().catch(() => {});
  };
  film.addEventListener('play', () => {
    userPaused = false;
  });
  film.addEventListener('pause', () => {
    // A pause while the film is visible (and the tab is open) is the visitor's choice; honor it.
    if (inView && !document.hidden) userPaused = true;
  });
  new IntersectionObserver(
    entries => {
      inView = entries[0].isIntersecting;
      if (inView) tryPlay();
      else film.pause();
    },
    { threshold: 0.35 },
  ).observe(film);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) film.pause();
    else tryPlay();
  });
}

// A native modal keeps focus inside the image viewer and restores it on close.
const imageLinks = [...document.querySelectorAll('.af-screen')];
if (imageLinks.length) {
  const viewer = document.createElement('dialog');
  viewer.className = 'af-image-viewer';
  viewer.setAttribute('aria-label', 'Lectern screenshot');
  viewer.innerHTML = `<div class="af-viewer-toolbar"><p>Inside Lectern</p><div><button type="button" class="af-viewer-zoom" aria-pressed="false">Zoom in</button><button type="button" class="af-viewer-close" autofocus>Close <span aria-hidden="true">×</span></button></div></div><div class="af-viewer-canvas"><img alt=""></div>`;
  document.body.append(viewer);
  const picture = viewer.querySelector('img');
  const canvas = viewer.querySelector('.af-viewer-canvas');
  const zoom = viewer.querySelector('.af-viewer-zoom');
  let opener;
  let previousOverflow;
  function resetZoom() {
    viewer.classList.remove('is-zoomed');
    zoom.setAttribute('aria-pressed', 'false');
    zoom.textContent = 'Zoom in';
    canvas.scrollTo(0, 0);
  }
  for (const link of imageLinks) {
    link.removeAttribute('target');
    link.setAttribute('aria-haspopup', 'dialog');
    link.addEventListener('click', event => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      opener = link;
      picture.src = link.href;
      picture.alt = link.dataset.fullAlt || link.querySelector('img').alt;
      resetZoom();
      previousOverflow = document.body.style.overflow;
      document.body.style.overflow = 'hidden';
      viewer.showModal();
    });
  }
  viewer.querySelector('.af-viewer-close').addEventListener('click', () => viewer.close());
  viewer.addEventListener('click', event => {
    if (event.target === viewer || event.target === canvas) viewer.close();
  });
  zoom.addEventListener('click', () => {
    const enlarged = viewer.classList.toggle('is-zoomed');
    zoom.setAttribute('aria-pressed', String(enlarged));
    zoom.textContent = enlarged ? 'Fit to screen' : 'Zoom in';
  });
  viewer.addEventListener('close', () => {
    document.body.style.overflow = previousOverflow;
    resetZoom();
    opener?.focus({ preventScroll: true });
  });
}
