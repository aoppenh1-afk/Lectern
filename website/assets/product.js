// Native app screenshot tabs. Keep the first screenshot available without JavaScript.
const tabs = [...document.querySelectorAll('.af-tabs [role="tab"]')];
function selectTab(tab) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
}
for (const [index, tab] of tabs.entries()) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    selectTab(tabs[next]);
    tabs[next].focus();
  });
}
// Silent demo film autoplays when scrolled into view, pauses when out of view.
const film = document.querySelector('.af-movie video');
if (film) {
  film.muted = true; // Required for autoplay policies; the clip has no audio.
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
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
      picture.alt = link.querySelector('img').alt;
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
