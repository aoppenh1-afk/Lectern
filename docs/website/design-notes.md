# Website redesign

Continued from thread `a0c2e6a0-efb9-4122-b0b7-9ba26cc6ff37` on September 17, 2026. The user's latest direction was to preserve the classroom hero and demo, replace the unrelated colors and invented interface cards with a consistent forest-green design, use actual app screenshots, and make a product video.

The lower page now follows the course library, lecture notes and transcript, then flashcards and exports. Forest green, warm paper, serif headings, and Outfit body text repeat throughout. Screenshot tabs support arrow keys, Home, and End. Screenshots open in a native modal with zoom, Close, Escape, and focus restoration. Modified clicks retain normal link behavior. The existing classroom and interactive demo remain above this sequence.

## Assets

`assets/app/` contains fresh cursor-free native Lectern captures. These are actual app screens. The library, notes, transcript, and flashcard captures are used directly, without invented overlays. The earlier generated study photograph remains on disk but is no longer displayed.

`assets/lectern-product.mp4` is a silent 32-second HyperFrames film, 1600 × 1000 at 30 fps. Editable source and its local image, font, and GSAP dependencies are in `videos/lectern-product/`. The video uses a manual play control, a poster, and no autoplay. Playback pauses offscreen and when the page is hidden. The camera follows lecture selection, generation choices, scrolling notes, and the flashcard editor. The notes transition is labeled as previously generated material. No generation, card save, or Anki sync was submitted. The scrolling recording is cropped to exclude the cursor and recording indicator.

The root website and the portable `website/` copy use the same HTML, product CSS, product JavaScript, screenshots, film, and poster.

## Verification

- HyperFrames check: no errors, no runtime/layout/motion issues, and 35/35 contrast checks passed. Three reviewed lint warnings concern the reused cards image and dense timeline tracks. The render also warned about sparse source-video keyframes; output frames were checked for visible scrolling.
- Website checked at 1440, 1024, 768, 390, and 320 pixels without horizontal overflow.
- Keyboard tabs, sample TSV download, and lower-page WCAG A/AA checks passed.
- Native film metadata verified as H.264, 1600 × 1000, 30 fps, 32 seconds. Rendered frames reviewed across the whole sequence.
- Screenshot viewer checked at 1440, 390, and 320 pixels: no new tab, zoom works, Close and Escape work, focus returns, page scrolling restores.
- Static website build and git whitespace checks passed.

Screenshot widths are capped by viewport height on desktop so section titles, descriptions, and screenshots fit together. Verified at 1366 × 768, 1280 × 800, 1440 × 900, and 1920 × 1080. Mobile retains its available width.
