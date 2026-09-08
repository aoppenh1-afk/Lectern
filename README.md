# Lectern

Lectern is a macOS app for students. It records lectures and shiurim — from a microphone in the room, or from Zoom and other system audio on this Mac — transcribes them (English and mixed English‑Hebrew), and turns them into nested outline notes, flashcards and quizzes. Optionally it syncs Canvas courses, deadlines and grades, and pushes notes to Google Docs.

Lectern launches [Google's official Antigravity ACP agent](https://github.com/agentclientprotocol/registry/tree/main/antigravity-acp) on your Mac and uses its separate Google sign-in. Lectern has no server and collects nothing.

## Requirements

- macOS 26 or later, Apple silicon
- Xcode 26 (full Xcode, not only Command Line Tools) to build from source
- A Google account with access to Antigravity
- Optional: a Canvas personal access token; a Google Cloud OAuth desktop client for Google Docs

## Install from a release

1. Open the [latest release](https://github.com/aoppenh1-afk/Lectern/releases/latest) and download `Lectern-<version>.zip`.
2. Unzip it and drag `Lectern.app` into **Applications**.
3. Clear the download quarantine so macOS will open the ad-hoc signed build:

```bash
xattr -dr com.apple.quarantine /Applications/Lectern.app
open /Applications/Lectern.app
```

You can also do this from System Settings › Privacy & Security › Open Anyway. Either way, you only do it the first time; in-app updates do not trigger it again.

4. Complete the setup assistant:
   - **Antigravity** (required). Click *Install Antigravity* so Lectern can download and verify Google's official ACP runtime, then click *Sign in with Google*. The normal `agy` CLI is not required and its sign-in is intentionally separate.
   - **Canvas** (optional). School Canvas address plus a personal access token (Canvas › Account › Settings › Approved Integrations › New Access Token). Stored in Keychain.
   - **Google Docs** (optional). Needs your own OAuth client from Google Cloud Console. Most people skip this.

Rerun the assistant from **Settings › General**.

## Install this repo for the user

Use this section when a person asks an AI agent (Codex, Claude, Cursor, and so on) to install Lectern from GitHub. Do the work on their Mac; do not hand them a list of steps unless a step requires their Google or Canvas sign-in.

1. Confirm the machine is Apple silicon on macOS 26 or later, and that Xcode 26 is installed (`xcodebuild -version`). If Xcode is missing, install it from the App Store and run `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch` before building.
2. Install Homebrew if it is missing, then `brew install xcodegen`.
3. Clone this repository and enter it:

```bash
git clone https://github.com/aoppenh1-afk/Lectern.git
cd Lectern
```

4. Build the Release app, ad-hoc sign it, and install it to `/Applications`:

```bash
scripts/install-local.sh
```

Done when `/Applications/Lectern.app` exists and `defaults read /Applications/Lectern.app/Contents/Info.plist CFBundleShortVersionString` prints a version.
5. Clear Gatekeeper quarantine (the app is ad-hoc signed; there is no Developer ID):

```bash
xattr -dr com.apple.quarantine /Applications/Lectern.app
open /Applications/Lectern.app
```

6. In Lectern's setup assistant, have the user click *Install Antigravity*. Lectern downloads the pinned official ACP runtime from Google, verifies its SHA-256 and identity, and keeps it under Application Support.
7. Have the user click *Sign in with Google* and complete Google's browser flow. No Terminal command or normal Antigravity CLI installation is required.

Do not commit tokens, `.env` files, or Keychain material. Do not change `git config`. Do not force-push.

## Updating

Lectern checks this repository's GitHub Releases about once a day and offers to install a newer build in place (**Settings › General › Check for updates**, or Lectern menu › Check for Updates…). It downloads the zip, verifies the checksum, swaps the app, and relaunches.

You can also download any version from the [Releases page](https://github.com/aoppenh1-afk/Lectern/releases).

## Other agents

Antigravity ACP is the default. **Settings › Agents** manages its runtime and Google account separately, and detects other supported agents on this Mac (ChatGPT via `codex-acp`, OpenCode).

All three use the bundled [Lectern notes skill](.agents/skills/lectern-notes/SKILL.md), which contains separate layouts for English lectures and English-Hebrew shiurim. No separate skill installation or access to the author's notes is needed. Google Docs sync keeps headings and lists left to right and uses invisible left-to-right marks around Hebrew phrases so surrounding punctuation and numbers stay in the LTR sentence. The export format version is part of the sync hash, so the next sync can reformat existing notes without regenerating them.

## Building from source

```bash
brew install xcodegen
git clone https://github.com/aoppenh1-afk/Lectern.git
cd Lectern
scripts/install-local.sh
```

`project.yml` is the source of truth. After you edit it, run `xcodegen generate`. Or open `Lectern.xcodeproj` in Xcode 26 and run the `Lectern` scheme.

```bash
xcodebuild -scheme Lectern -destination 'platform=macOS' test
```

## Publishing a release (maintainer)

Releases currently use a persistent self-signed certificate. This preserves the designated requirement, but does not prevent repeated Keychain prompts: macOS also checks a per-build code-hash partition for self-signed apps. A stable certificate alone is insufficient.

Builds and releases are pinned to the original `Lectern Release Signing` certificate fingerprint in `scripts/release-signing.sh`. On another Mac, import the existing `.p12` backup into your login Keychain. Creating a new certificate with the same name does not preserve Keychain access. The setup helper is only for establishing a new identity, not restoring this app's release identity.

Run a release with:

```bash
scripts/release.sh 1.3.1 --notes "What changed"
```

The scripts refuse a missing or different certificate and verify the finished app against the pinned signing requirement before packaging. For a disposable local build only, use `LECTERN_SIGN_IDENTITY=- scripts/build-app.sh`. Such builds may require Keychain authorization again.

With self-signed releases, **Always Allow** may need to be repeated after each rebuild. Apple Development signing can provide a stable team partition for personal development builds; Developer ID is the signing route for public distribution. Neither eliminates prompts when the login Keychain itself is locked.

This verifies the signing identity, bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, builds and signs the app bundle with the persistent certificate, zips, commits, tags `v1.3.1`, pushes, and creates the GitHub release with the zip and its `.sha256`. Installed copies pick it up on their next check.

## Privacy

- Recordings, transcripts and notes stay in `~/Library/Application Support/Lectern`.
- Zoom / system-audio capture uses ScreenCaptureKit. macOS gates that behind Screen & System Audio Recording permission; Lectern discards the dummy video frames and stores only the WAV.
- Canvas tokens, Google Docs OAuth state and transcription API keys are stored in the macOS Keychain. The official Antigravity ACP agent stores its own credential in a private Lectern profile.
- Antigravity prompts and supported attachments are sent through ACP. Lecture audio uses ACP's native audio content block instead of a workspace path hint.
- This repository does not contain credentials. Do not commit `.env` files or tokens.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
