# Publish Lectern's website

The `website/` folder contains a complete static site. No package installation,
build command, database, analytics, or OAuth credentials are needed. The files are
also packaged in `dist/Lectern-website.zip`, with `index.html` at the archive root.
The site is not live until you publish it.

## Use the existing Lectern repository

1. Commit and push `website/` and `.github/workflows/website.yml` to the `main`
   branch of `aoppenh1-afk/Lectern`. Include this guide if useful. Keep the OAuth
   JSON, `.build/`, `dist/`, and local build logs out of GitHub.
2. In GitHub, open the repository's **Settings → Pages**.
3. Under **Build and deployment → Source**, choose **GitHub Actions**.
4. Open **Actions → Publish Lectern website → Run workflow**, select `main`, and run.
5. Wait for deployment to succeed. Open the URL shown by the deployment.
   For this repository, the expected default URL is
   `https://aoppenh1-afk.github.io/Lectern/`.
6. Open Privacy and Terms from the homepage and confirm all pages are public
   without signing in. Review the policy, including the published support address
   `senderopp@gmail.com`, before using it for your public OAuth registration.

The workflow publishes only `website/`, so existing internal `docs/` files and the
application source are not part of the website. Publication is manual. After site
changes, run the workflow again.

## Or upload the zip to a separate website repository

Unzip `dist/Lectern-website.zip` and upload its contents to the new repository's
root. Do not upload the zip file itself. Choose **Settings → Pages → Deploy from a
branch → main → /(root)**. Relative links work with either a repository URL or a
custom domain. Use the URL GitHub provides instead of the example above.

## Complete Google Branding after publication

If using the existing repository and default Pages address, enter:

| Google field | Value |
| --- | --- |
| Application home page | `https://aoppenh1-afk.github.io/Lectern/` |
| Application privacy policy link | `https://aoppenh1-afk.github.io/Lectern/privacy.html` |
| Application terms of service link | `https://aoppenh1-afk.github.io/Lectern/terms.html` |
| Authorized domain | `aoppenh1-afk.github.io` |

Do not use `github.com` or the shared `github.io` suffix as your authorized domain.
For a different GitHub account or a custom domain, replace these values accordingly.

Use the Google account that owns the OAuth project to verify the site in
[Google Search Console](https://search.google.com/search-console/). For GitHub Pages,
use a **URL-prefix** property and the HTML-tag verification method. Add Google's
exact verification meta tag inside `<head>` in `website/index.html`, republish,
then click Verify. Keep the tag in place afterward. If Google requires verification
at the account-site root, publish a verification page in the
`aoppenh1-afk.github.io` repository and verify `https://aoppenh1-afk.github.io/`.
Do not attempt DNS verification for `github.io`, which you do not own.

Save Branding, publish the External audience in **Audience**, and follow the
Verification Center's remaining checks. Site ownership verification is separate
from Google's approval of OAuth branding; the website files do not guarantee
approval. If Google rejects the hosted subdomain or verification scope, use the
specific message to resolve it before distributing the Google Docs connection.

## Local OAuth configuration

The supplied Desktop client was validated for Google project `lectern-508021`.
Its values are saved in `.build/GoogleOAuth.xcconfig`, which Git ignores. The local
`scripts/build-app.sh` reads this file automatically, and explicit
`LECTERN_GOOGLE_CLIENT_ID` / `LECTERN_GOOGLE_CLIENT_SECRET` environment settings can
override it. Preserve the original downloaded JSON if you clear `.build/` or build
on a different Mac. The file is not included in the website archive.

The shared client identifies a public Desktop app and is embedded in the built
app's Info.plist. User refresh tokens stay in each user's Keychain. No personal
Google session or refresh token is bundled. Publishing the website does not change
the Google project's audience or verification status.

References: [GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages),
[Google site verification](https://support.google.com/webmasters/answer/9008080),
[Google brand verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification).
