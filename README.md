# Lectern

Lectern is a macOS app for students. It records lectures and shiurim, transcribes them (English and mixed English‑Hebrew), and turns them into nested outline notes, flashcards and quizzes. Optionally it syncs Canvas courses, deadlines and grades, and pushes notes to Google Docs.

All AI work runs on your Mac through [Google's Antigravity CLI](https://antigravity.google/docs/cli/overview) using your own Google sign-in. Lectern has no server and collects nothing.

## Requirements

- macOS 26 or later, Apple silicon
- Xcode 26 (full Xcode, not only Command Line Tools) to build from source
- A Google account for Antigravity CLI
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
   - **Antigravity CLI** (required). Install with the command it shows, run `agy` once in Terminal to sign in with Google, then click *Check again*. Lectern's transcription and notes skills are built into the app.
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

6. Install Antigravity CLI if `agy` is not on `PATH` (it usually lands in `~/.local/bin`):

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

7. Tell the user to run `agy` once in Terminal and finish the Google sign-in in the browser. You cannot complete that sign-in for them. After they are done, Lectern's setup assistant *Check again* button should show Antigravity as ready.

Do not commit tokens, `.env` files, or Keychain material. Do not change `git config`. Do not force-push.

## Updating

Lectern checks this repository's GitHub Releases about once a day and offers to install a newer build in place (**Settings › General › Check for updates**, or Lectern menu › Check for Updates…). It downloads the zip, verifies the checksum, swaps the app, and relaunches.

You can also download any version from the [Releases page](https://github.com/aoppenh1-afk/Lectern/releases).

## Other agents

Antigravity CLI is the default. **Settings › Agents › Detect installed agents** finds other supported agents on this Mac (ChatGPT via `codex-acp`, `opencode`) and fills in their paths.

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

```bash
scripts/release.sh 1.2.0 --notes "What changed"
```

This bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, builds and ad-hoc signs, zips, commits, tags `v1.2.0`, pushes, and creates the GitHub release with the zip and its `.sha256`. Installed copies pick it up on their next check.

## Privacy

- Recordings, transcripts and notes stay in `~/Library/Application Support/Lectern`.
- Canvas tokens, Google OAuth state, transcription API keys and any GitHub token are stored in the macOS Keychain.
- Each Antigravity job runs sandboxed in a fresh private temp folder that contains only the audio or transcript and Lectern's skill file, and is deleted afterwards.
- This repository does not contain credentials. Do not commit `.env` files or tokens.
