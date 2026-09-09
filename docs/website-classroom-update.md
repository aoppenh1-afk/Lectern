# Classroom demo update

The root homepage places the interactive laptop in a persistent classroom scene. The display uses the native app's 1470 × 923 canvas proportions, scaled into the laptop without cropping the sidebar. Expand demo provides a larger view. Seven scroll chapters change the lecture panel and caption. Interacting with the app enters Explore mode temporarily; the next scroll chapter resumes the story, including when focus remains inside the demo. Wheel input over the unexpanded laptop scrolls the page. Expanded view keeps normal app-panel scrolling.

The browser recreation uses the native SwiftUI shell, Canvas workspace views, subscriptions screen, Settings structure, and theme as layout references. The botanical sidebar image comes from the app's assets. The classroom image was generated for this page on September 9, 2026 and stored locally as a 286 KB JPEG.

The workspace tabs now have distinct layouts and sample interactions:

- Calendar has month, week, and day views with date navigation.
- Assignments has course and status filters, search, and readable assignment previews.
- Courses has the native column layout and lecture outputs. The sample includes transcript, cleaned transcript, notes, bilingual flashcards, quiz, and local export.
- Subscriptions has search, check, pause, resume, remove, and link-preview controls.
- Grades has course cards and a detail panel.
- Resources has module navigation, course and type filtering, search, and content previews.
- Announcements has a list and reading pane.
- AI Chat has a course selector, source panel, multiline composer, clear action, and local sample answers.
- Settings has ten sections with sample preferences and connection previews.

Validation completed on September 9, 2026:

- JavaScript syntax checks for demo and story modules.
- `node scripts/test-website-state.mjs` covers navigation, calendar dates, filters, preview readers, grades, subscriptions, source selection, Settings panes, recording lifecycle, bilingual decks, quiz scoring, CSV contents, chat escaping, and reset.
- Chrome visual checks covered Calendar, Resources, Subscriptions, AI Chat, Settings, and Announcements. Browser interactions checked assignment search, course-specific chat, resource previews, and reset. No console errors were reported.
- Narrow-screen checks at 390 × 844 covered navigation, subscription layout, and grades. The page had no horizontal overflow. The viewport override was reset afterward.
- `git diff --check` passed.

This is a browser recreation with sample data, not a pixel-by-pixel parity guarantee. Recording, transcription, AI, account connections, imports, and Google Docs exports are simulations. They do not access the visitor's microphone, files, or accounts. CSV and Markdown exports create local sample downloads.

The local preview was updated without committing, pushing, or publishing. GitHub Pages continues to use the repository root. The older `website/` duplicate remains unchanged.

## Larger screen and page content

The laptop now opens at up to 980 pixels wide with more space above it, placing it lower against the classroom. Once scrolling begins, the introductory heading leaves the stage and the laptop fits the available viewport while preserving its native aspect ratio. The story caption and chapter controls remain beneath the screen.

New sections below the demo explain recording, transcripts, study materials, Canvas organization, bilingual notes, exports, and practical setup questions. Copy was checked against the repository README.

`node scripts/test-website-story.mjs` reproduces the former Explore/focus scroll blockage and now passes. It also checks that wheel events advance the story while expanded mode preserves app scrolling. Browser checks confirmed scroll progression after clicking Calendar, later chapters, and explanatory content. The full screen was checked at 1224 × 780, and mobile page width at 390 × 844 showed no horizontal overflow. Viewport overrides were reset.

## Warm classroom reference — September 9
- Added `assets/classroom-warm.jpg`, a generated clean background plate based on the supplied mockup, preserving the interactive HTML laptop.
- Added chalk-style margin notes, workflow icons, a hand-drawn headline underline, and rounded download CTA with arrow.
- Increased scroll focus scale from 7% to 15%; it returns to normal as the scene exits. Narrow screens and reduced-motion settings retain their static presentation.
- Verified the hero and focused laptop in Chrome. Story and workspace state checks pass, along with JavaScript syntax and diff whitespace checks.
