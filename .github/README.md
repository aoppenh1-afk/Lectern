# GitHub automation

Lectern uses standard GitHub-hosted runners. These are free for this public
repository under [GitHub's Actions billing policy](https://docs.github.com/en/actions/concepts/billing-and-usage).
The added checks need no paid service or new secrets.

| Check | Purpose | When |
| --- | --- | --- |
| macOS CI | Build and test the app, verify release-signing policy, check Word/PDF exports, run hosted integration and website regression tests, and build the site | Pull requests, main pushes, manual runs |
| Dependency review | Fail a check when a PR introduces a dependency with a known high or critical vulnerability | Pull requests |
| CodeQL | Scan hosted JavaScript and GitHub Actions for security defects | Pull requests, main pushes, weekly, manual runs |
| Workflow lint | Catch invalid Actions syntax, expressions, job dependencies, and action inputs with actionlint | Pull requests, main pushes, manual runs |
| Dependabot | Propose updates for Actions, hosted npm dependencies, and Python DMG packaging dependencies | Weekly for Actions/npm, monthly for packaging |
| CodeRabbit | Review PR changes for correctness, security, and Lectern-specific regressions using `.coderabbit.yaml` | Ready PRs targeting the default branch and follow-up commits |
| Dev builds | Publish signed dev-channel prereleases using the existing release-signing environment | Main pushes except stable release commits, manual runs |

Dependabot groups compatible npm and packaging updates and caps open PRs. Major
package updates remain separate. Updates require review; nothing auto-merges.
Packaging updates still need a local DMG smoke test because CI does not package a
signed release. Dependabot does not manage AppAuth in `project.yml`, and this
configuration does not update the vendored Parakeet package.

Dependency review covers supported dependencies recorded in GitHub's dependency
graph. It is not a complete audit of vendored code or XcodeGen package declarations.
It needs the repository dependency graph enabled in GitHub's security settings.
CodeQL results appear in the Security tab. Its scope here is JavaScript and
Actions, not native Swift. Native checks use Xcode 26 through `macos-26`.

CI runs the three portable Node website regressions. The browser QA scripts remain
local checks; they need a running site and browser setup. Word/PDF export checks
run on macOS and cover formatting, pagination, and mixed Hebrew/English text.

Workflow actions are pinned to commit SHAs and tracked by Dependabot. The
actionlint binary is pinned to v1.7.12 with its release SHA-256; update the version
and checksum together in `workflows/workflow-lint.yml`. To check workflows locally,
install actionlint and run `actionlint -shellcheck= -pyflakes=` from the repo root.

These files take effect after they are pushed to GitHub. Scheduled scans and
Dependabot use the default branch. Checks report failures; requiring them before
merge is a separate branch-rule setting. Dev publishing keeps its existing push
trigger and does not wait for CI. Stable releases still use `scripts/release.sh`.

CodeRabbit needs its GitHub App installed with access to Lectern. Its repository
configuration keeps reviews advisory and skips drafts, generated Xcode files,
vendored code, video projects, and lockfiles. Dependency checks still cover
supported lockfiles. Review vendored changes separately. Summaries stay in the
bot's walkthrough comment, and docstring coverage/generation prompts are disabled.
Automatic guideline-file loading is disabled because the repository's AGENTS.md
requires local MCP tools. The configuration supplies review guidance directly.

After pushing the configuration, open a ready PR to confirm the bot reviews it.
On an existing PR, comment `@coderabbitai review` to request a review or
`@coderabbitai configuration` to inspect the effective settings. Direct pushes to
main do not receive this PR review. See the [configuration reference](https://docs.coderabbit.ai/reference/configuration)
and [review commands](https://docs.coderabbit.ai/reference/review-commands).
