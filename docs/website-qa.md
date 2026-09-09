# Lectern website QA — automated browser run

Harness: `scripts/test-website.mjs` (this contributor's only code file).
No implementation files were edited. No commits.

## How to run

```sh
# Driver lives ONLY in approved temp, never in the project:
npm i playwright-core --prefix "/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa" --no-audit --no-fund

PLAYWRIGHT_MODULE=/var/folders/fv/6dlmy35s18zg0tk8vs9b_4180000gn/T/opencode/lectern-qa/node_modules/playwright-core \
  BASE_URL=http://127.0.0.1:8765/Lectern/ node scripts/test-website.mjs
```

`BASE_URL` override and `--json`, `--headed`, `--timeout`, `--only` flags supported.
`PLAYWRIGHT_MODULE` accepts `playwright`, `playwright-core`, or a path to either
(file or directory). Chromium resolves from the local ms-playwright cache or
`PLAYWRIGHT_EXECUTABLE`. Static server serves `/Users/sender/Projects`.

## Latest result: 64 PASS, 0 FAIL, 0 SKIP

Run against the live static server while builders were still editing.
Covered, per `docs/website-redesign-plan.md` acceptance gates:

- Overflow: home/privacy/terms at 1440, 1280, 1024, 768, 390, 320, plus 1440x500.
  No page-level horizontal scroll anywhere.
- Home/privacy/terms load HTTP 200 at every width.
- No failed same-origin asset requests; no console/page errors; no off-origin
  requests (no analytics, no third-party fonts) across the full matrix.
- Demo: `#lectern-demo` present, "Sample demo. No recording or uploads."
  persistent, all nine nav entries (Overview … AI Chat) present as
  `[data-act='nav']` buttons, 3/3 nav clicks switch panels, lecture tabs switch,
  flashcard `[data-act='flip']` reveals + prev/next page, quiz `[data-act='answer']`
  shows inline feedback ("Not quite — the answer is highlighted.") with score and
  Retake restoring unanswered state, capture rec-start runs a simulated timer and
  rec-reset returns to 00:00 with double-reset stable and no duplicate lectures.
- Click-then-scroll: after Explore, full-page scroll preserves Explore mode and
  demo text. Reduced motion: media query honored, demo stable over 2.5 s idle,
  manual controls work. Keyboard: focus inside demo survives scroll, Tab moves
  without trapping. No-JS: static Overview preview, download and legal links work.
- Legal: all 51 privacy and 24 terms HEAD sentences present (case- and
  punctuation-tolerant comparison; restyle adds nav/TOC only), `#google` anchor
  present and reachable. Required links (releases/latest, privacy, terms,
  contact mailto) present.

## Harness bugs found and fixed during this run (harness-side, not site bugs)

- Legal comparison was case-sensitive; `.legal-eyebrow` uses
  `text-transform:uppercase`, so innerText mismatched source. Now case-insensitive.
- Tag-stripping left "gmail.com ." vs rendered "gmail.com.". Now punctuation-tolerant.
- Explore button hides once Explore mode is active (Resume appears instead);
  the check now resets the sample first. Quiz Retake returns to the capture tab;
  later checks account for that.

## Caveats for owners

- `demo lecture tabs` reports 1/2 because the suite opens on the transcript tab
  (clicking it is a no-op by design). Not a site defect.
- `assets/demo.js` changed underfoot during QA (tab set differed between two
  manual probes minutes apart). Re-run the harness after builders finish; it
  exits non-zero on any FAIL and SKIPs (never fails) demo steps whose controls
  do not exist yet, so it stays useful on partial builds.
- Expand-demo modal (Escape / focus return) and 200%-zoom tap-target audit were
  probed manually but are not yet in the harness; candidates for a follow-up.
