# Persistent native login sessions

The VPN clients for Android, iOS, macOS, Windows, and Linux use `AuthRepository`
for all authenticated gateway traffic. `main` restores the session before
constructing `GatewayController`. `WalletAuthController` owns the lifecycle
observer and checks freshness on resume; requests also check freshness themselves.
No suspended-app timer is needed for login renewal.

## Storage and ownership

`AuthSessionStore` commits the complete session as one JSON item through
`flutter_secure_storage`, scoped to this VPN app and gateway. It bypasses the
project's desktop preferences fallback. Keychain/Keystore failures fail the
operation rather than persisting secrets in preferences. Existing legacy secure
items/preferences are migrated once and removed. A secure sign-out tombstone
prevents leftover legacy items from restoring an old login.

`AuthRepository` registers a main-isolate owner with `IsolateNameServer`.
Every repository proxy for the same gateway, including background Flutter
isolates, queues credential operations on that owner. Initialize it on the main
isolate first (as startup already does); background workers must use these
clients/repository instead of accessing secure storage or refreshing directly.
Only freshness checks, rotation, persistence, and account mutations are serialized;
protected HTTP requests run concurrently after obtaining a token.

Access tokens remain opaque. Absolute gateway expiry metadata is preferred;
relative lifetimes are converted to absolute UTC at receipt. Access within 60
seconds of expiry is renewed. The replacement, including refreshed inactivity
expiry, is committed before waiting requests receive it. A rejected protected
request with `401 ACCESS_TOKEN_EXPIRED` is replayed once with its original encoded
body and headers; a late rejection reuses an already-renewed access token.

## Failures and account changes

Only `REFRESH_TOKEN_INVALID`, `REFRESH_TOKEN_REUSED`, and `SESSION_REVOKED`
terminate authentication. Other failures keep credentials, profile data, and
entitlements. `429` renewal responses persist `Retry-After` (seconds and HTTP date
are supported), so concurrent calls and restarts cannot bypass the delay.

Before sending a rotation or legacy upgrade, the owner commits an uncertainty
marker. A definite failure before HTTP submission allows a later foreground
attempt. After submission, a timeout, lost response, malformed success, 5xx, or
failed replacement write leaves the marker intact. No generic retry can reuse
that credential, even after a crash/restart; one new login is necessary without
an additional server recovery protocol. Account/user data is retained. A
successful new login replaces the marker.

Logout and account replacement invalidate pending operations using a generation
counter immediately, then queue behind any rotation. Logout revokes the latest
known refresh credential, clears the secure session, and clears local account/VPN
data. Offline logout still clears local auth and displays that remote revocation
is unconfirmed. A new account clears the old account's profile and entitlements;
late protected responses cannot be applied across account generations.

Legacy bearers are upgraded through `/api/v2/auth/session` once. An expired
legacy bearer or `409 SESSION_ALREADY_REFRESHABLE` records that one login is
required, preventing an upgrade loop. The desktop browser callback remains a
bearer handoff; refresh credentials belonging to the separate Erebrus webapp are
never copied into the VPN app. A callback carrying an already-refreshable webapp
bearer cannot be upgraded under the supplied gateway contract; the user must
complete a native email/Google/Apple/wallet login. A future desktop browser
handoff needs a server-issued, app-bound exchange code that creates a distinct
VPN session, rather than exporting the webapp's refresh credential.

## Browser builds

This repository ships native VPN clients; `web/` is Flutter's generated scaffold,
and the gateway/VPN runtime depends on `dart:io` and native plugins. Native session
storage explicitly refuses Web. Enabling a functional Flutter Web client requires
a server-side browser session/BFF with HttpOnly cookies and server-owned refresh
rotation. The supplied native bearer contract does not define that backend;
refresh secrets must never be placed in localStorage, IndexedDB, or preferences.

## Verification

`test/auth_repository_test.dart` covers expiry, restart/resume, concurrent calls,
background isolates, persistence ordering, replay limits, provider parsing,
legacy upgrades, revocation, transient/uncertain failures, Retry-After, and logout
and account switching during rotation. `test/session_transport_test.dart` checks
actual HTTP payloads, missing access bearer on rotation/logout, and Retry-After.
Native device QA is still needed to verify OS Keychain/Keystore entitlements and
provider UI on each shipping platform.
