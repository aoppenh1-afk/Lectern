# Lectern

Lectern is a macOS app for students. It records lectures and shiurim, transcribes them (English and mixed English‑Hebrew), and turns them into nested outline notes, flashcards and quizzes. Optionally it syncs Canvas courses, deadlines and grades, and pushes notes to Google Docs.

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

Releases require a persistent code signing certificate so macOS Keychain items (Canvas tokens, Google Docs OAuth, transcription API keys) remain accessible across updates without repeatedly prompting the user.

If you have not set up the release certificate on this Mac yet, run the one-time helper:

```bash
scripts/setup-signing-cert.sh
```

This creates a 20-year self-signed `Lectern Release Signing` certificate in your login keychain and saves a backup `.p12` archive to your Desktop (`Lectern-Release-Signing-BACKUP.p12`, password: `lectern`). **Keep this `.p12` file backed up safely** so you can preserve the app's signing identity if you ever switch machines.

To publish a release:

```bash
scripts/release.sh 1.3.1 --notes "What changed"
```

This verifies the signing identity, bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, builds and signs the app bundle with the persistent certificate, zips, commits, tags `v1.3.1`, pushes, and creates the GitHub release with the zip and its `.sha256`. Installed copies pick it up on their next check.

## Privacy

- Recordings, transcripts and notes stay in `~/Library/Application Support/Lectern`.
- Canvas tokens, Google Docs OAuth state, transcription API keys and any GitHub token are stored in the macOS Keychain. The official Antigravity ACP agent stores its own credential in a private Lectern profile.
- Antigravity prompts and supported attachments are sent through ACP. Lecture audio uses ACP's native audio content block instead of a workspace path hint.
- This repository does not contain credentials. Do not commit `.env` files or tokens.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
