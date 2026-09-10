# Lectern

Lectern is a macOS app for students. It records lectures and shiurim — from a microphone in the room, or from Zoom and other system audio on this Mac — transcribes them (English and mixed English‑Hebrew), and turns them into nested outline notes, flashcards and quizzes. Optionally it syncs Canvas courses, deadlines and grades, and pushes notes to Google Docs.

Lectern launches [Google's official Antigravity ACP agent](https://github.com/agentclientprotocol/registry/tree/main/antigravity-acp) on your Mac and uses its separate Google sign-in. Lectern has no server and collects nothing.

## Requirements

- macOS 26 or later, Apple silicon
- Xcode 26 (full Xcode, not only Command Line Tools) to build from source
- A Google account with access to Antigravity
- Optional: a Canvas personal access token; a Google account for Google Docs

## Install from a release

1. Follow the [illustrated installation guide](install.html), or download `Lectern-<version>.dmg` from the [latest release](https://github.com/aoppenh1-afk/Lectern/releases/latest).
2. Open the DMG and drag Lectern onto the **Applications** folder in the installer window. Wait for copying to finish, then eject the installer. ZIP downloads are also available: unzip and drag `Lectern.app` into Applications.
3. Clear the download quarantine so macOS will open the ad-hoc signed build:

```bash
xattr -dr com.apple.quarantine /Applications/Lectern.app
open /Applications/Lectern.app
```

You can also do this from System Settings › Privacy & Security › Open Anyway. Either way, you only do it the first time; in-app updates do not trigger it again.

4. Complete the setup assistant:
   - **Antigravity** (required). Click *Install Antigravity* so Lectern can download and verify Google's official ACP runtime, then click *Sign in with Google*. The normal `agy` CLI is not required and its sign-in is intentionally separate.
   - **Canvas** (optional). School Canvas address plus a personal access token (Canvas › Account › Settings › Approved Integrations › New Access Token). Stored in Keychain.
   - **Google Docs** (optional). Click Connect Google Docs and approve access in your browser. The distributed app must include Lectern’s shared OAuth client.

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

**Settings › General › Update channel** switches tracks: **Stable** follows tested releases, published only when a new release is cut; **Dev** follows every commit on main via prereleases and may break. Switching back to Stable offers the latest stable release as the way out.

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


### Google Docs release configuration

Users connect their Google account in Settings → Google Docs. Lectern requests only
`https://www.googleapis.com/auth/drive.file`, with no full-Docs, full-Drive, email, or
profile scope. Google Docs supports this scope for creating documents, reading their
tabs, and updating them. Tokens remain in the macOS Keychain. AppAuth uses the system
browser, a loopback redirect, and PKCE. No hosted OAuth backend is needed.

The app maintainer must configure one shared Google Cloud project before distributing
this feature:

1. Enable Google Docs API and create an OAuth client of type **Desktop app**.
2. Configure the external audience, Lectern branding, support contact, homepage and
   privacy policy. List only `drive.file` under Data Access. Remove the old
   `documents` scope from the consent configuration.
3. Move the audience to **In production** for distribution. Complete any brand
   verification Google requests. Testing mode still limits users and can show
   warnings; changing code does not publish or verify the Google project.
4. Supply `LECTERN_GOOGLE_CLIENT_ID` and `LECTERN_GOOGLE_CLIENT_SECRET` as Xcode build
   settings, or export both variables before running `scripts/build-app.sh`.
   Use the downloaded Desktop client values. They identify a public desktop client
   and are embedded in Info.plist, so they are extractable from the app. Never use
   a web-server client secret here or treat these values as confidential credentials.
5. Test a release build with a separate Google account: connect, push two lectures
   in one course, edit and push one again, restart the app and push again. Confirm
   one document with two tabs, updated content, and no unexpected consent warning.

Builds without a client show an unavailable message instead of credential fields.
Existing sessions from a different client or with broader requested scopes require
reconnection. Local sign-out does not revoke old Google grants; users can remove
those in their Google Account connections. A new Google project may not be able to
read documents created by the old client. If Google returns 404, Lectern leaves the
old document intact and creates a replacement on the next push. Other API errors
remain visible instead of silently creating duplicates.

Google lists `drive.file` as non-sensitive, so it avoids sensitive/restricted scope
review. This does not guarantee that every account or project will show no warning.
Standard Docs API use is currently available at no additional cost, subject to
Google’s quotas. Google currently plans charges for exceeding those quotas later
in 2026, so this is not a promise of unlimited free use. See [Docs scopes](https://developers.google.com/workspace/docs/api/auth),
[usage limits](https://developers.google.com/workspace/docs/api/limits), and
[brand verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification).

### DMG packaging

Releases publish a drag-to-Applications DMG for new installs and keep the ZIP plus checksum for in-app updates. `scripts/package-dmg.sh /path/to/Lectern.app /path/to/Lectern-version.dmg` packages an existing signed app without rebuilding it. It requires macOS and Python 3 with venv support, and installs the pinned packaging dependencies from `scripts/dmg-requirements.txt` into the ignored `dist/.dmg-tools` environment.

### Read lectures from ChatGPT or Claude (MCP)

Open **Settings → ChatGPT & Claude**, sign in with Google, select courses, and
click **Start sharing**. Lectern uploads only course names, lecture titles/dates,
notes, and raw/cleaned transcripts to your hosted account. Changes sync about every
30 seconds while the app is open. The last synced copy remains readable when the
Mac is closed. Removing a course takes effect after a successful sync.

Add `https://lectern-app.vercel.app/mcp` as a custom MCP connection in ChatGPT or
Claude, choose OAuth authentication, and sign in with the same Google account.
Enable Lectern in your conversation. The AI can browse courses, search lectures
(including Hebrew), and read paged notes/transcripts with source line numbers.
Account and workspace settings in the AI product may restrict custom connectors.

The **Manage connections and shared data** link opens `/connect` on the website.
Disconnect individual apps there, or use **Delete hosted library and disconnect
all apps** to delete the hosted copy and revoke access. Your Mac's original library
is kept. Copies already retrieved by an AI service are governed by that service.
Deleting from the Mac requires an online confirmation; a failed request does not
claim that cloud access was revoked.

This replaces the former local server and private tunnel URLs. No tunnel or
terminal setup is required for students. The site maintainer must provision the
backend once before the connection works: see [Hosted MCP deployment](docs/hosted-mcp.md).

Run `npm run test:hosted` for the hosted database/OAuth/MCP integration tests and the
normal Xcode scheme for native app checks. The hosted tests use an isolated
embedded Postgres database and a fake Google identity provider; they do not upload
real lecture content or substitute for testing real Google/ChatGPT/Claude accounts.
