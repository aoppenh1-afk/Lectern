# Lectern website redesign

Status: researched and reviewed plan. No website implementation or deployment in this phase.

## Direction

Build the homepage around a working sample of Lectern, framed by a laptop on a classroom desk. The classroom belongs outside the app window. Preserve the real app inside it.

Choose a morning classroom rather than a dark study room. Warm paper, moss green, quiet wood tones, and daylight fit the app's existing design. Borrow T3 Code's large typography, clear download action, and emphasis on the product. Do not copy its black palette, floating provider logos, or testimonial wall.

The first impression should be a place to study with Lectern already open. Avoid a stock classroom photo with a screenshot pasted over it. Build a restrained scene with a desk edge, soft window light, and an out-of-focus board. Keep the laptop nearly front-on so text stays readable. No WebGL or 3D asset is required.

## Completed delegation

All five contributors ran through the installed OpenCode CLI with `-m opencode/muse-spark-1.3-contributor-free --variant xhigh`. The first three ran in parallel. The fourth reviewed their proposed direction independently. The fifth read this plan and checked for blocking contradictions. All returned completed reports. These were CLI agent sessions, not Task-tool agents with an assumed model.

| Contributor | Assignment | Result |
| --- | --- | --- |
| Visual research | T3 and other references, classroom treatment, palette and typography | Two directions; morning classroom selected |
| App fidelity and architecture | Current SwiftUI shell, theme, demo states, static hosting | Actual Overview entry, theme tokens, duplicated website files |
| Story and quality | Page sequence, interaction rules, mobile, accessibility, privacy | Guided lecture-to-study story and acceptance checks |
| Independent critic | Challenge fidelity, scope, input ownership, legal and deployment risks | Readability, simulation labels, explicit tour controls, legal text preservation |
| Final plan reviewer | Read the written plan for blockers and unsupported completion claims | No blockers; remaining visual reference, control, Hebrew, and performance checks remain explicit |

The orchestrator checked source evidence, inspected T3 in a browser, and confirmed Pages configuration through the GitHub API. Contributor recommendations below are filtered rather than accepted wholesale.

## Research evidence

| Reference | Evidence obtained | What to use |
| --- | --- | --- |
| https://t3.codes/ | Direct fetch and desktop browser screenshot | Oversized centered headline, restrained navigation, one strong download action, broad product image, concrete workflow sections |
| https://stripe.press/ | Contributor direct fetch, not a verified visual screenshot | Editorial/book framing as a direction to test, not a measured typography specification |
| https://www.descript.com | Contributor direct fetch | Named workflow steps with product examples and late-page objection handling |
| https://www.khanacademy.org/ | Fetch returned a JavaScript requirement | No usable design evidence; do not cite as support |
| https://www.duolingo.com/ | Fetch returned insufficient content | No usable design evidence; do not cite as support |

Web search was unavailable because its provider lacked authentication. Direct fetching worked. Before the visual prototype gate, inspect Stripe Press and Descript in a browser and retain screenshots. Text extraction cannot establish animation timing, exact colors, or typography.

## Verified product and hosting facts

- `Sources/Lectern/LecternApp.swift:214-215` creates `SuperAppShellView` in the main window.
- `Sources/Lectern/Views/SuperAppShellView.swift:4-34` defines Overview, Calendar, Assignments, Courses, Subscriptions, Grades, Resources, Announcements, and AI Chat.
- That file defaults to Overview at line 48 and sets a minimum native window of 1180 by 760 at line 90.
- `Sources/Lectern/Theme/GlassStyle.swift:3-10` specifies paper, serif document titles, sans-serif chrome, hairlines, and restrained surface changes.
- The same theme file defines moss `#1A5336`, paper `#FAF9F7`, ink `#293029`, and selected sage `#E1ECE0`. Keep recording red and processing purple where the native app uses them.
- The current root homepage and `website/index.html` were directly read and are identical. Both describe lectures, mixed English-Hebrew shiurim, study materials, and optional Google Docs.
- GitHub API `repos/aoppenh1-afk/Lectern/pages` reports legacy Pages, branch `main`, source `/`, HTTPS enabled. Live URL is https://aoppenh1-afk.github.io/Lectern/.
- The checked graph generation was `2026-09-03T19:29:56Z`. Relevant Swift metadata had changed; website files were not tracked by freshness metadata. Direct reads supplied the evidence. Coverage is not a completeness guarantee.

The implementation must verify lecture-detail controls and their labels before copying them. A graph hit alone does not prove a behavior is present or current.

## Visual specification

| Element | Decision |
| --- | --- |
| Page background | Warm paper `#FAF9F7`; warmer classroom light only in the surrounding scene |
| Primary text | Green-black `#293029` |
| Primary action | Moss `#1A5336` with tested contrasting text |
| Selected fills | Sage `#E1ECE0` with dark text |
| Secondary decoration | Muted oak and amber, never the only indicator of meaning |
| Marketing headings | Trial Fraunces, locally hosted, with Georgia fallback |
| Body and app chrome | System sans-serif stack; preserve native serif document titles |
| Hebrew | System fallback first; test glyphs and punctuation before adding a font |
| App panels | Match actual theme radii, dividers, spacing, labels, and hierarchy |
| Site sections | Broad editorial sections and rules, not repeated feature-card grids |

Do not restyle the app to match the marketing font. Use its actual serif and sans hierarchy. Cap optional web fonts at one family initially.

The laptop is framing, not the main attraction. In the hero, keep the headline short enough that the Overview screen and an invitation to interact are visible without a long scroll. Offer an expanded demo view for comfortable reading. On mid-size screens, remove decorative space before shrinking controls.

## Page story

Use one fictional course and lecture through the sequence. A short memory-and-learning lecture is an accessible candidate. Add a separate reviewed English-Hebrew sample, not a mixture of unrelated content presented as one lecture. Do not use a student's real grades, recordings, calendar, or name.

| Chapter | Proposed copy | Visual and action |
| --- | --- | --- |
| Arrival | Keep the lecture. Make it your notes. | Classroom and laptop, real Overview shell. Download for Mac and Try the demo. Requirements beside the download. |
| Before class | Your day, already in view. | Sample schedule and course context in Overview. Open the course. Clearly identify sample Canvas data. |
| Capture | Start with the lecture. | Demonstrate the actual capture entry with a short seeded recording sequence. No device permission request. |
| Review | Read what was said. | Open a sample transcript. Show the app's real navigation and review controls after verifying source. |
| Study | Turn it into something you can study. | Outline, flashcard reveal, and a small answerable quiz. Keep the same sample facts across all outputs. |
| Shiurim | English and Hebrew, in the same notes. | Switch to a reviewed mixed-language sample. Preserve the native outline order and mixed punctuation. |
| Return | Come back ready. | Show the saved lecture and optional Google Docs action. Explain that pushing again updates the lecture tab. |
| Trust and download | Your library on your Mac. Your choice of providers. | Plain account of local storage and provider processing, requirements, install help, source, privacy, terms, contact. |

Keep the main study sequence compact. The Hebrew example can be a sample selector within the study chapter rather than another long pinned section. Canvas is context and optional sync, not an invented export destination.

Home, privacy, and terms receive one shared visual language. Keep the existing release and installation destinations. A separate download page is unnecessary unless the installation content no longer fits a short home section.

## Interaction contract

The browser demo reproduces the app's visible interface and representative interactions. It does not run the native Swift app or reproduce its services. Label it persistently: "Sample demo. No recording or uploads."

Use two explicit modes: Guided tour and Explore the app. Scrolling may select chapter previews in Guided tour. A click, touch, or meaningful keyboard action inside the app enters Explore mode. Scroll still moves the page normally but cannot overwrite demo state. A visible Resume tour button is the only way back. Preserve the explored state separately so resuming is not destructive.

- Never move keyboard focus, play audio, submit a quiz, flip a card, or simulate a service action because of scroll.
- Pause automatic chapter swaps while focus is inside the demo, even before a control activates.
- Native page scrolling always works. Do not capture wheel events to advance slides.
- An expanded demo has an obvious close action, Escape support, and focus return. Prefer an in-page expansion unless a modal is necessary.
- Use a shared deterministic sample state for course, lecture, selected output, flashcard, quiz answer, and mode. Keep story position separate.
- Reset restores all seeded state and cancels timers. Repeated actions must not create duplicate lectures or exports.
- Use local sample content. No microphone, file picker, authentication, real model, Canvas, or Docs request.
- Label cloud-related examples as simulated. Do not show an apparent successful export into a real account.
- Keep all nine native navigation entries. Each must open a source-verified sample panel or a clear explanation that the section is outside the sample. No dead buttons.
- Do not invent controls such as transcript click-to-seek or user-editable grades without checking the app.

Prioritize complete study interactions before filling secondary navigation. Do not build nine backend simulations to make the demo appear broad.

## Mobile and motion

At narrow widths, remove the laptop bezel and classroom decoration. Show a readable single-pane adaptation of the same sample with an honest "Mac app demo, adapted for this screen" label. Do not suggest that Lectern has a native phone app.

Choose breakpoints by measured readability, not a rule that a 1180px native window must fit every web viewport. No scaled-down interactive text. Support 320px widths and 200% zoom without page-level horizontal scrolling.

Use a small number of motions: a short entrance, chapter crossfades, and subtle environmental depth outside the UI. No perpetual bobbing, spinning laptop, typewriter paragraphs, or animated counters.

Reduced motion removes parallax, automatic screen changes, and card-flip transforms. Keep manually selectable, instant demo state changes. Story content remains visible in normal document order. Without JavaScript, render a useful static Overview preview, story text, and working download/legal links.

Keep English-Hebrew outlines LTR where the actual notes format is LTR. Isolate Hebrew runs or blocks with appropriate language and direction markup. Do not set the whole document or all notes to RTL. Review punctuation and nested numbering with a fluent reader.

## Technical scope

Start with static HTML, CSS, and small JavaScript modules. GitHub Pages needs no server for this demo. Avoid a framework migration unless the prototype establishes a concrete need.

| Owner | Exclusive write scope during implementation |
| --- | --- |
| Visual implementer | `style.css` and local scene/font assets |
| Demo implementer | Proposed `assets/demo.js`, `assets/demo.css`, and seeded sample module |
| Story implementer | Proposed `assets/story.js`; no direct mutation of demo internals |
| Page integrator | `index.html`, imports, shared navigation, metadata, fallback markup |
| Legal-page implementer | `privacy.html`, `terms.html`, legal-only styles |
| QA contributors | Browser evidence and test files; report fixes to owners |

Agree on CSS prefixes, sample state, and the demo/story API before parallel writing. One owner edits each file. The page integrator performs cross-file changes after contributors finish, not concurrently with them.

Root remains the published source. Preserve current Pages configuration. Leave `website/` unchanged during the first build, explicitly record it as a stale duplicate, and do not link to it. Audit inbound uses before any separate removal, redirect, or generated-mirror cleanup. Do not silently maintain two handwritten versions.

Read the full privacy and terms pages before restyling. Preserve wording and existing anchors, including `privacy.html#google`. Check extracted legal text before and after rather than assuming a markup diff proves preservation. Any substantive legal correction is a separate review item.

All asset paths must work under `/Lectern/`, including ES-module imports. Use self-hosted assets with recorded licenses. No analytics or third-party font requests by default. No native app edits are needed.

## Delivery waves and supervision

All future delegated work retains the same Muse Spark model and xhigh setting unless the user changes that requirement. Never silently substitute a model after a provider failure.

1. Evidence and design proof. Two parallel contributors capture a safe native UI reference set and inspect remaining web references. A visual contributor then produces the hero at desktop and phone sizes. Review composition before coding the full page.
2. Static hero and app shell. Visual and demo contributors work in separate files from approved references. Integrate Overview and one course. Reject tiny text, invented navigation, and generic dashboard substitutes here.
3. Interaction and story. Demo contributor completes the lecture, outline, card, quiz, and sample export path. Story contributor adds chapters through the agreed API. Legal contributor restyles the supporting pages in parallel.
4. Independent review. Separate fidelity, accessibility/interaction, and visual/performance contributors inspect the integrated result. They do not approve their own implementations. Each finding includes a screenshot or reproducible steps, severity, and responsible owner.
5. Revision and verification. Route findings to owners, inspect new screenshots at the same sizes, and rerun failed tests. Finish only with resolved blockers or an explicit list of remaining limitations. Commit, push, or deploy only when requested.

Use enough contributors for independent work, not ten people editing the same hero. At each checkpoint, record completed outputs, active work, blockers, and changes requested. Inspect tool results and actual artifacts. An agent's claim that a page looks good is not approval.

## Acceptance gates

### Visual and fidelity

- Review actual screenshots at 1440, 1280, 1024, 768, 390, and 320 CSS pixels, plus a short-height desktop viewport.
- Compare the desktop demo beside a safe screenshot of the current native app. Match entry screen, navigation order, selected fills, type hierarchy, and real control names.
- Hero has one clear focal point, the app. Classroom decoration never obscures controls or requires a long wait to see the product.
- Phone layout reads at normal text size. The laptop is not merely shrunk to fit.
- No generic feature grid, invented usage metrics, fake testimonials, placeholder content, or unlicensed classroom art.
- The Hebrew example receives language review. Until then it is not approved launch content.

### Behavior and access

- Complete the sample course-to-quiz path with mouse, touch, and keyboard.
- Test click-then-scroll, focus-then-scroll, rapid chapter changes, reset during a timer, resume tour, and resize during Explore mode.
- No focus traps. Visible focus and semantic controls throughout. Tabs have keyboard behavior if using tab roles.
- Body contrast at least 4.5:1; large text and required non-text controls at least 3:1. Test actual combinations.
- Tap targets at least 44px where practical. Verify at 200% zoom and with reduced motion.
- No microphone, upload, provider, or authentication prompts. Observe network traffic through the full demo, not just on load.
- Static content and download/legal navigation survive disabled JavaScript.

### Performance and publishing

- Initial budget: at most 60KB compressed first-party JavaScript and 1MB initial page transfer. Prefer less. Lazy-load optional scene assets, never the primary product preview.
- Target LCP below 2.5 seconds, CLS below 0.1, and lab interaction latency below 200ms on an agreed throttled profile. Lab measurements are not field Core Web Vitals claims.
- Set dimensions on assets, keep fonts local, and avoid third-party scripts. Test cold loads.
- No console errors, missing assets, or broken links under the actual `/Lectern/` base path.
- Confirm requirements remain macOS 26 or later and Apple silicon. Keep download, installation guide, GitHub, contact, and legal links working.
- Legal text preservation and existing fragment links pass review. No misleading blanket offline or privacy claim.

## Decisions made during review

The raw reports contained suggestions that should not reach the build: exporting to Canvas, opening on a made-up Library screen, forcing all Hebrew notes RTL, and adding three font families. The critic also proposed banning serif text inside the app, which conflicts with the real theme. Preserve native serif document titles instead.

Do not claim exact feature parity with the Mac app. The target is a faithful, clearly labeled interactive sample. If full functional parity is required, that is a separate browser-product project, not a static Pages redesign.

The next deliverable is a reviewed desktop and mobile hero prototype, followed by the interactive site. This document does not claim the redesigned site has been built, visually approved, or deployed.
