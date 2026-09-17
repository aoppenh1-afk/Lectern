# Antigravity upstream review, September 16, 2026

Compared Lectern's original managed ACP port, `0978ba9`, with t3code's Antigravity changes through `6d1d5494`. The fetched nightly tags included `v0.0.43-nightly.20260916.1825` and `v0.0.43-nightly.20260917.1837`. This review focuses on the managed runtime, settings, authentication, and process lifecycle.

## Picked up

- **Runtime 1.1.1 and update controls.** Use the macOS ARM64 URL, SHA-256, archive size, and executable sizes from [t3code's verified release](https://github.com/pingdotgg/t3code/blob/6d1d5494/apps/server/src/provider/antigravityRelease.ts). Settings → Agents now compares the installed runtime with that release, shows both versions when an update is available, and offers Check for updates and Update Antigravity. Like [upstream's settings](https://github.com/pingdotgg/t3code/blob/6d1d5494/apps/web/src/components/settings/ProviderSetupSection.tsx), this uses a release pinned in the application. It does not fetch arbitrary newer binaries from a remote manifest.
- **Sign-in links on stderr.** [Upstream fix #9514](https://github.com/pingdotgg/t3code/commit/eb334ca57448742139fb8ec38fb397c1e51c45c5) handles the native 1.1.1 URL prefix as well as the browser helper. Lectern now handles both, including lines split between reads, validates URLs, and reports sign-in required for background connections. Authorization lines are excluded from the diagnostic buffer.
- **Temporary runtime files.** [Upstream fix #12008](https://github.com/pingdotgg/t3code/commit/8c18b5bb21a5349fbadba8c77456ea34c41b7339) addresses PyInstaller extraction directories left behind by stopped runtimes. Lectern now gives each process its own temporary directory and removes it after process exit. Update checks only inspect installation files. Refresh no longer launches a separate identity-validation process before checking authentication. Unlike upstream, this change does not sweep directories left by a crash of Lectern itself.
- **Update failure handling.** Cancellation is checked before activation. Failed or cancelled updates retain the previous active installation. Concurrent refreshes cannot overwrite install progress, and reinstall checks leases again before replacing files.

## Other changes assessed

- [Model-choice updates #9511](https://github.com/pingdotgg/t3code/commit/baf67b6e3accd48d510fd0d39a4e6b978a1eea80) are useful for long-lived chat sessions. Lectern already requests model entries from ACP when loading the catalog. Handling changes pushed during an existing session remains a separate improvement.
- [Remembered sign-in #10244](https://github.com/pingdotgg/t3code/commit/c8872fd22aadb8d155f1bedc10576d8314f93e56) repairs t3code's provider snapshot bookkeeping. Lectern checks the runtime's authenticated session directly and keeps credentials in its existing private profile, so that implementation does not transfer directly.
- Upstream also added subagent result display and broader user/workspace skill discovery. These are more relevant to a coding workspace than Lectern's lecture workflows. They are not included here.

## Validation

The focused Antigravity suite exercises update detection without executing a binary, missing/corrupt/current installations, preservation of the active release after rejected validation, both stderr sign-in formats, bounded stderr buffering, process-exit cleanup, and existing native-audio transcription behavior. Tests use local fixture processes; no user's installed runtime or Google account is changed. A real 1.1.1 download and Google sign-in have not been exercised in this review.
