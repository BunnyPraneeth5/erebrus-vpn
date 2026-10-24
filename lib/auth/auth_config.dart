// Config: project-root `.env` (bundled into the app) or `--dart-define-from-file`.

/// Reown (WalletConnect) project id — Android / iOS wallet login.
const kReownProjectId = String.fromEnvironment('REOWN_PROJECT_ID');

/// True when [kReownProjectId] was passed via `--dart-define` / `.env`.
bool get hasReownProjectId => kReownProjectId.isNotEmpty;

/// Google Sign-In **server** (web) client id — its audience must be listed in the
/// gateway's `GOOGLE_CLIENT_IDS`. Client ids are public identifiers (never the
/// secret), so the production one is baked in; override via `--dart-define` for
/// a different Google Cloud project. Empty => Google sign-in is hidden (no
/// native call, no error).
const kGoogleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
const kDefaultGoogleServerClientId =
    '743089346496-15iub9ug9b4jkqonokg2js80ndjv8nba.apps.googleusercontent.com';

/// Bundle-specific Google OAuth client for `com.erebrus.vpn`. OAuth client IDs
/// are public app identifiers, so this is intentionally checked into source.
const kGoogleIosClientId =
    '743089346496-fq5j5npvhmqqa3lsfj6gqctlph7o53tp.apps.googleusercontent.com';

/// Apple Sign-In Services id + redirect, needed only for the web/Android relay
/// flow; on iOS/macOS native Apple sign-in uses the app's capability instead.
/// Absent (and not on Apple platforms) => Apple sign-in is hidden.
const kAppleServiceId = String.fromEnvironment('APPLE_SERVICE_ID');
const kAppleRedirectUri = String.fromEnvironment(
  'APPLE_REDIRECT_URI',
  defaultValue: 'https://gateway.erebrus.io/api/v2/auth/apple/callback',
);

/// Erebrus webapp origin (`EREBRUS_WEB_ORIGIN` in `.env` / `--dart-define`).
/// Wallet logo + MWA identity derive `{origin}/vpn/logo.png` from this value.
const kErebrusWebOrigin = String.fromEnvironment(
  'EREBRUS_WEB_ORIGIN',
  defaultValue: 'https://erebrus.io',
);

/// Production origin used when [kErebrusWebOrigin] points at localhost — wallets
/// must fetch `…/vpn/logo.png` over public HTTPS, not loopback.
const kErebrusProductionOrigin = 'https://erebrus.io';

/// Webapp route that performs wallet auth and redirects with a PASETO token.
const kErebrusDesktopAuthPath = '/auth';

/// Deep link the webapp redirects to after auth (`erebrusvpn://auth?token=…`).
const kErebrusAuthCallbackScheme = 'erebrusvpn';
const kErebrusAuthCallbackHost = 'auth';
const kErebrusAuthCallback = 'erebrusvpn://auth';

/// Gateway chain identifier for Solana wallet login.
const kSolanaChain = 'sol';

/// VPN app path on the erebrus site (`/vpn/logo.png`, `/vpn/`, …).
const kErebrusVpnBasePath = '/vpn';
const kErebrusVpnLogoFile = 'logo.png';
const kErebrusVpnLogoPath = '$kErebrusVpnBasePath/$kErebrusVpnLogoFile';

String _erebrusOriginBase(String webOrigin) =>
    webOrigin.replaceAll(RegExp(r'/+$'), '');

/// Trailing-slash site URL for WalletConnect / Reown metadata (`url` field).
String erebrusSiteUrlFromOrigin(String webOrigin) =>
    '${_erebrusOriginBase(webOrigin)}/';

/// Absolute HTTPS icon for Reown / WalletConnect pairing metadata.
String erebrusSiteIconFromOrigin(String webOrigin) =>
    '${_erebrusOriginBase(webOrigin)}$kErebrusVpnLogoPath';

/// MWA identity URI — the `/vpn/` base so the icon can be a simple filename
/// (`logo.png`), matching the `favicon.ico` pattern wallets expect.
String erebrusMwaIdentityUrlFromOrigin(String webOrigin) =>
    '${_erebrusOriginBase(webOrigin)}$kErebrusVpnBasePath/';

/// Mobile Wallet Adapter icon filename relative to [erebrusMwaIdentityUrlFromOrigin]
/// (resolves to `{origin}/vpn/logo.png`). Wallets reject absolute icon URLs.
const kErebrusMwaIconRelative = kErebrusVpnLogoFile;

/// Native deep link — wallets return here after connect/sign (`erebrusvpn://…`).
const kErebrusNativeRedirect = 'erebrusvpn://';

/// Universal link placeholder for Reown metadata (host assetlinks when ready).
const kErebrusUniversalRedirect = 'https://erebrus.io/vpn';

/// Shown when a wallet button is tapped in a build without REOWN_PROJECT_ID
/// (set it in `.env` or the `REOWN_PROJECT_ID` CI secret, then rebuild).
const kReownProjectIdMissingMessage =
    'Wallet login isn\'t available in this build yet. '
    'Please sign in with email for now.';

/// macOS / iOS bundle id — sent to the webapp as `client_id`.
const kErebrusBundleId = 'com.erebrus.vpn';

/// Linux APPLICATION_ID.
const kErebrusLinuxApplicationId = 'com.erebrus.erebrus_vpn';

String reownOriginNotAllowedMessage(String relayOrigin) =>
    'Reown relay rejected this app (origin not allowed). In cloud.reown.com → '
    'your project → Allowlist, add: $relayOrigin and https://erebrus.io — then '
    'wait ~15 minutes and restart the app.';
