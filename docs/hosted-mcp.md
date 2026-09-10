# Hosted Lectern connection

This replaces the app’s local MCP listener, private URL secrets, and manual HTTPS
tunnel. The Vercel site serves `/mcp`, `/connect`, OAuth discovery/authorization,
and the authenticated Mac upload API. Students use one public URL and approve
access by signing in. The maintainer must provision the database and Google Web
OAuth client once; deploying static HTML alone does not enable this service.

## Maintainer setup

1. **Postgres:** connect a Postgres database to the existing Lectern Vercel project
   through [Vercel Marketplace](https://vercel.com/marketplace?category=storage&search=postgres).
   Neon is one option. Use a database dedicated to Lectern and copy its pooled
   connection string into the project's **Production** `DATABASE_URL` environment
   variable. Require TLS, as in `?sslmode=require`; do not disable certificate
   verification. Review the provider's region, backups, retention and pricing.
2. **Google sign-in:** in [Google Auth Platform](https://console.cloud.google.com/auth/clients),
   create a **Web application** OAuth client, separate from the Desktop app client
   used for Google Docs. Register this exact authorized redirect URI:
   `https://lectern-app.vercel.app/auth/callback`.
   Configure branding, audience and the `openid` and `email` scopes. Testing-mode
   accounts must be explicitly allowed by Google; publish the audience for general
   availability and complete any branding requirements Google presents.
3. **Server environment:** set the following Vercel Production variables. Values
   must remain server-side; do not add them to Swift, Info.plist, or static assets.

   | Variable | Value |
   | --- | --- |
   | `LECTERN_ORIGIN` | `https://lectern-app.vercel.app` |
   | `DATABASE_URL` | Dedicated Postgres connection string |
   | `GOOGLE_CLIENT_ID` | Web application client ID |
   | `GOOGLE_CLIENT_SECRET` | Web application client secret |
   | `CRON_SECRET` | Random 32-byte secret for daily cleanup |

   Generate the cleanup secret locally with
   `node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"`.
   Use separate database and OAuth credentials for preview/testing environments.
   Never connect a preview to production data. A different hostname needs matching
   `LECTERN_ORIGIN` and a separately registered Google callback.
4. **Migration:** with Node 20.19+ and the target database environment available,
   run `npm ci --ignore-scripts`, then `npm run db:migrate`. Alternatively, with an
   ignored `.env.hosted` file, use
   `node --env-file=.env.hosted scripts/migrate-hosted.mjs`.
   The migration is additive and repeatable; it is never run on incoming requests.
5. **Deploy:** deploy this repository to the existing Vercel project. Keep root
   directory at the repository root and use the checked-in `vercel.json` settings.
   The build assembles `.vercel-site` and deploys `api/hosted.mjs` alongside it.
   Production OAuth and MCP endpoints must be publicly reachable without Vercel
   deployment-protection login. Access to lecture data is protected by Lectern's
   own authorization. Vercel runs the authenticated cleanup job daily.
6. **Verify:** run `node scripts/check-hosted-deployment.mjs` for the public
   discovery/auth boundary checks, then complete the real-account checks below.
   Build the Mac app with the normal Xcode process and distribute it only after
   the hosted connection has passed those checks.

Google/Vercel credentials and a production database are not included in the repo.
The hosted tests do not provision these services or prove a production deployment
is configured. See [Google's OpenID Connect setup](https://developers.google.com/identity/openid-connect/openid-connect)
and [Vercel Postgres integrations](https://vercel.com/docs/postgres).

## Student setup

1. In Lectern, open **Settings → ChatGPT & Claude** and sign in with Google.
2. Choose courses or Unfiled lectures, then click **Start sharing**. Wait for the
   successful sync message.
3. Add `https://lectern-app.vercel.app/mcp` in ChatGPT or Claude with OAuth
   authentication. Sign in with the same Google account and approve read access.
4. Enable Lectern in the conversation and ask for a course, lecture or topic.

[ChatGPT connection instructions](https://developers.openai.com/plugins/deploy/connect-chatgpt)
and [Claude custom connector instructions](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)
cover account-specific availability and setup. The server publishes OAuth metadata
and supports dynamic client registration; users do not need an API key or client
secret. Third-party clients receive only `library:read`; the fixed native client
can request `library:sync` using S256 PKCE and a loopback callback. The loopback
listener exists only during native sign-in, not as an MCP server.

## Data and access behavior

- Each account owns one hosted selection. Uploads contain only the Codable
  `LecternCloudSnapshot` fields. Recordings, attachments, chats, quiz content,
  provider credentials and Google Docs content are not read by this connection.
- The app checks/syncs every 10 minutes while open, and when a course selection
  changes. A successful sync atomically replaces the hosted snapshot. Deselected
  or deleted lectures disappear only after that successful sync. The last copy
  remains available offline and its timestamp is returned with every tool result.
- Revisions prevent another device from silently overwriting the hosted selection.
  **Replace hosted selection** is an explicit review action. An account change
  clears the previous account's local course-selection preference.
- Uploads use 384 KiB byte chunks and a final commit; incomplete uploads are never
  read by MCP. Limits: 32 MiB per account snapshot, 1,000 courses, 10,000 lectures,
  at most five staging uploads per account. Staging uploads expire after 30 minutes.
- `/connect` lists grants and permits individual revocation. Deleting the hosted
  library also revokes all grants, clears pending consent/codes and staging data,
  and prevents connected Macs from silently restoring the copy. Account identity
  remains for sign-in; hosting backups follow the configured provider's retention.
- Browser sessions last seven days. Access tokens last one hour; refresh tokens
  rotate and expire after 30 days. Refresh-token replay revokes that grant. Tokens,
  authorization codes and sessions are stored as SHA-256 hashes. Mac authorization
  state is in Keychain. Google ID tokens are validated for signature, issuer,
  audience, nonce and verified email; Google API tokens are not retained.
- OAuth redirects match registered HTTPS URLs exactly. All clients use S256 PKCE;
  authorization codes are single-use, short-lived, and audience-bound. Consent
  forms show the destination origin and are protected by session-bound CSRF tokens.
- Same-origin checks protect browser forms, and MCP accepts cloud requests without
  browser Origin headers. The public endpoint accepts only bearer tokens; the
  public URL itself grants no access. Application logs omit sensitive payloads.
- Daily cleanup removes expired staging uploads, pending logins/codes, sessions,
  tokens and rate buckets. Failed/expired uploads never become visible even before
  cleanup. Monitor Vercel cron execution; a missing `CRON_SECRET` fails closed.

## AI navigation

`list_courses` → `list_lectures` → `get_lecture` → `read_document` is the standard
path. `search` matches all query words across titles, course names and documents,
including Hebrew, and returns excerpts and stable opaque lecture IDs. List tools
return `next_offset`; document reads return `next_start_line`. Source lines over
2,000 Unicode code points are split into stable lines; pages contain at most
24,000 code points. The server uses the official MCP SDK's stateless Streamable
HTTP implementation and read-only annotations. It does not implement a separate
ChatGPT research `search`/`fetch` contract.

## Validation and operations

Run `npm run test:hosted` for isolated Postgres, OAuth, upload and real MCP SDK
client tests. Run `npm run build` for the static site and the normal Xcode scheme
for the Mac app. The Mac tests include snapshot allowlist/encoding checks. Tests
use a fake Google identity provider; production always verifies Google's signed
ID token using Google's JWKS.

Before release, use real accounts to check:

- Google sign-in from the Mac, then ChatGPT and Claude consent flows.
- Two accounts with different lectures: neither can read the other's content.
- Course navigation, Hebrew search and complete reading of a long transcript.
- Editing/deleting notes and deselecting a course, followed by a successful sync.
- Mac restart and refresh-token persistence; two Macs with a revision conflict.
- Closing the Mac while reading the last synced copy from the AI.
- Individual grant revocation and hosted deletion from the browser, including
  deletion while a Mac upload is in progress. Old tokens must stop working.

For emergency shutdown, remove the `/mcp` rewrite/deploy or revoke grants in the
service; do not rely on changing a public URL. Rolling back the website or Mac
binary does not delete hosted data. To retire the service, revoke grants and
remove hosted records deliberately before deprovisioning the database. Keep the
additive schema when rolling back a deployment so user data is not lost.
