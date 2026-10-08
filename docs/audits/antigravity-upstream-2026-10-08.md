# Antigravity upstream review, October 8, 2026

Lectern still targeted `agy_acp_server_1.1.1` from the September review. Its Check for updates action compares the installed version record with `AntigravityACPRelease.current`; it does not fetch Google's registry. An installed 1.1.1 runtime therefore appeared current even after Google released 1.3.0.

T3 Code uses the same application-pinned release approach. Its [October 5 update](https://github.com/pingdotgg/t3code/commit/4dbc0129c244d5869d7598a22f8d9386cca17884) changed the target to 1.3.0. The [settings action](https://github.com/pingdotgg/t3code/blob/4dbc0129c244d5869d7598a22f8d9386cca17884/apps/web/src/components/settings/ProviderSetupSection.tsx) offers Update Antigravity when the installed version differs from that target. Neither managed installer discovers arbitrary new releases at runtime.

Lectern now matches the [verified ARM64 release metadata](https://github.com/pingdotgg/t3code/blob/4dbc0129c244d5869d7598a22f8d9386cca17884/apps/server/src/provider/antigravityRelease.ts), whose URL comes from the [official ACP registry](https://github.com/agentclientprotocol/registry/blob/dc55a34900fdd60e5e97c1cbd7825c5a1df673fc/antigravity-acp/agent.json). Settings names the installed version when it matches Lectern's verified release, so the result makes the scope of the check explicit. Future runtime releases still require updating Lectern's pin and shipping an app update.

Downloaded the official archive independently and checked its SHA-256, 111,456,962-byte archive size, and both member sizes against T3 Code's metadata. Initialized the real 1.3.0 executable with an isolated temporary profile. It reports protocol version 1, audio support, session load/resume, logout, and `oauth-personal`, matching Lectern's installation requirements. No Google sign-in or authenticated prompt was exercised.

Before the fix, the regression test reproduced the exact symptom: an installed `agy_acp_server_1.1.1` reported up to date instead of offering 1.3.0. The focused Antigravity suite covers this transition, current/missing/corrupt installation records, failed-update preservation, process leases, authentication parsing, cleanup, and native audio fixtures.

After the fix, all 27 tests passed with `xcodebuild -scheme Lectern -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:LecternTests/AntigravityACPTests test`.
