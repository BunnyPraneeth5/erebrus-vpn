import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_config.dart';
import 'runtime_config.dart';
import 'auth_session_store.dart';
import 'auth_repository.dart';
import 'deep_link_handler.dart';
import 'desktop_web_auth.dart';
import 'entitlement_state.dart';
import 'gateway_auth_client.dart';
import 'rank_summary.dart';
import 'referral_summary.dart';
import 'social_login.dart';
import 'user_profile.dart';
import '../platform/platform_capabilities.dart';
import 'solana_mobile_wallet.dart';
import '../vpn/gateway_controller.dart';
import '../vpn/vpn_models.dart';
import '../vpn/vpn_controller.dart';

/// Wallet login via MWA on Solana Mobile, Reown elsewhere, and gateway v2 auth.
class WalletAuthController extends GetxController with WidgetsBindingObserver {
  WalletAuthController({
    GatewayAuthClient? authClient,
    AuthSessionStore? store,
    AuthRepository? repository,
  }) : _authClient = authClient ?? GatewayAuthClient(),
       sessions =
           repository ??
           AuthRepository(store: store, gatewayUrl: authClient?.gatewayUrl) {
    _authClient.sessions = sessions;
    sessions.onChanged = (stored) {
      if (stored != null) {
        _applyStoredSession(stored);
      } else {
        final wasActive = isAuthenticated;
        _applyToken(null);
        _syncGatewayToken();
        if (wasActive && !_signingOut) unawaited(expireSession());
      }
    };
  }

  final GatewayAuthClient _authClient;
  final AuthRepository sessions;
  bool _signingOut = false;
  int? _webLoginGeneration;
  int? _walletLoginGeneration;

  bool _mayStartLogin() {
    if (_signingOut || _sessionExpiryInFlight != null) {
      authError.value = 'Finishing sign-out. Try again in a moment.';
      return false;
    }
    return true;
  }

  void _cancelProviderFlows() {
    _webLoginGeneration = null;
    _walletLoginGeneration = null;
    awaitingWebCallback.value = false;
    DesktopWebAuth.clearPendingState();
  }

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(restoreOnResume());
  }

  Future<void> restoreOnResume() async {
    if (_signingOut) return;
    if (!isAuthenticated) {
      await loadPersistedSession();
      return;
    }
    try {
      await sessions.ensureFresh();
      await refreshEntitlement();
      await refreshProfile();
    } on AuthException catch (e) {
      authError.value = e.message;
    } catch (_) {
      authError.value = 'Could not restore the secure session.';
    }
  }

  void _applyStoredSession(StoredAuthSession stored) {
    if (userId.value.isNotEmpty && userId.value != stored.userId) {
      _resetAccountData();
    }
    _applyToken(stored.token);
    _mwaAuthToken = stored.mwaAuthToken;
    walletAddress.value = stored.walletAddress;
    userId.value = stored.userId;
    role.value = stored.role;
    authMethod.value = stored.authMethod;
    _syncGatewayToken();
  }

  ReownAppKitModal? appKitModal;

  final walletAddress = ''.obs;
  final userId = ''.obs;
  final role = ''.obs;
  final authMethod = ''.obs;
  final isAuthenticating = false.obs;
  final reownReady = false.obs;
  final sessionReady = false.obs;
  final authError = RxnString();
  final entitlement = EntitlementState.none.obs;
  final isLoadingEntitlement = false.obs;
  final isRefreshingNft = false.obs;
  final profileEmail = ''.obs;
  final profileEmailVerified = false.obs;
  final profileName = ''.obs;
  final profileChain = ''.obs;
  final profileCreatedAt = Rxn<DateTime>();
  final isLoadingProfile = false.obs;
  final profileError = RxnString();
  final isLinkingEmail = false.obs;
  final referral = Rxn<ReferralSummary>();
  final rank = Rxn<RankSummary>();
  final isRedeemingReferral = false.obs;
  final entitlementError = RxnString();
  final awaitingWebCallback = false.obs;

  final isDeletingAccount = false.obs;
  final deleteAccountError = RxnString();
  final hasPendingDeletionRequest = false.obs;

  final accountOrgInvites = <UserOrgInvite>[].obs;
  final isLoadingAccountOrgInvites = false.obs;
  final accountOrgInvitesError = RxnString();

  /// Which login methods the gateway has configured (loaded best-effort) and
  /// whether Apple sign-in is usable on this device.
  final authMethods = AuthMethods.unknown.obs;
  final appleDeviceReady = false.obs;

  String? _token;
  String? _mwaAuthToken;
  Future<void>? _sessionExpiryInFlight;

  /// Mirrors [_token] for GetX — [RootView] must observe this, not the raw token.
  final sessionActive = false.obs;

  final isSolanaMobileDevice = false.obs;

  /// Native-login availability = gateway-configured AND app-side config present.
  bool get emailLoginAvailable => authMethods.value.email;
  bool get googleLoginAvailable =>
      authMethods.value.google && googleSignInSupported;
  bool get appleLoginAvailable =>
      authMethods.value.apple && appleDeviceReady.value;

  bool get isAuthenticated => sessionActive.value;
  bool get isEntitled => entitlement.value.entitled || role.value == 'admin';

  /// Whether the user may connect to the currently selected node.
  bool canConnectVpn(VpnNode? node) {
    if (isEntitled) return true;
    if (node == null || !node.isPrivateAccess) return false;
    if (entitlement.value.orgMember) return true;
    if (!Get.isRegistered<GatewayController>()) return false;
    final gw = Get.find<GatewayController>();
    return gw.orgNodes.any((n) => n.id == node.id);
  }

  bool get usesReown => PlatformCapabilities.usesReown;
  bool get usesWebLogin => PlatformCapabilities.usesWebLogin;
  String? get bearerToken => _token;

  /// Best-effort discovery of which login methods the gateway has configured, so
  /// the UI hides providers whose secrets are absent (no errors). Also probes
  /// native Apple availability. Failures leave the optimistic defaults.
  Future<void> loadAuthMethods() async {
    try {
      authMethods.value = await _authClient.fetchAuthMethods();
    } catch (e) {
      debugPrint('[Auth] auth methods unavailable, using defaults: $e');
    }
    try {
      appleDeviceReady.value = await appleSignInSupported();
    } catch (_) {
      appleDeviceReady.value = false;
    }
  }

  /// Requests an email login code. Returns true when sent.
  Future<bool> requestEmailLoginCode(String email) async {
    authError.value = null;
    try {
      await _authClient.emailLoginStart(email.trim().toLowerCase());
      return true;
    } on AuthException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    }
    return false;
  }

  /// Verifies an email login code and signs in (creates the account if new).
  Future<void> verifyEmailLoginCode({
    required String email,
    required String code,
  }) async {
    if (!_mayStartLogin()) return;
    final normalized = code.replaceAll(RegExp(r'\D'), '');
    if (normalized.length < 4) {
      authError.value = 'Enter the full code from your email';
      return;
    }
    authError.value = null;
    try {
      final loginGeneration = await sessions.generation();
      final session = await _authClient.emailLoginVerify(
        email: email.trim().toLowerCase(),
        code: normalized,
      );
      if (session.token.isEmpty) {
        authError.value = 'Sign-in succeeded but no session token was returned';
        debugPrint('[Auth] email verify: empty token from gateway');
        return;
      }
      await _persistSession(
        session,
        method: 'email',
        generation: loginGeneration,
      );
      await _afterLogin();
      debugPrint('[Auth] email login OK user=${session.userId}');
    } on AuthException catch (e) {
      authError.value = e.message;
      debugPrint('[Auth] email verify failed: ${e.message}');
    } on TimeoutException {
      authError.value =
          'Sign-in timed out — check your connection and try again';
    } catch (e) {
      authError.value = e.toString();
      debugPrint('[Auth] email verify error: $e');
    }
  }

  /// Google sign-in via the native chooser → gateway session.
  Future<void> signInWithGoogle() async {
    if (!_mayStartLogin()) return;
    if (isAuthenticating.value || !googleLoginAvailable) return;
    isAuthenticating.value = true;
    authError.value = null;
    try {
      final loginGeneration = await sessions.generation();
      final idToken = await googleIdToken();
      if (idToken == null) return; // cancelled
      final session = await _authClient.googleLogin(idToken);
      await _persistSession(
        session,
        method: 'google',
        generation: loginGeneration,
      );
      await _afterLogin();
      debugPrint('[Auth] google login OK');
    } on AuthException catch (e) {
      authError.value = e.message;
    } on SocialLoginException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    } finally {
      isAuthenticating.value = false;
    }
  }

  /// Apple sign-in via the native flow → gateway session.
  Future<void> signInWithApple() async {
    if (!_mayStartLogin()) return;
    if (isAuthenticating.value || !appleLoginAvailable) return;
    isAuthenticating.value = true;
    authError.value = null;
    try {
      final loginGeneration = await sessions.generation();
      final credential = await appleCredential();
      if (credential == null) return; // cancelled
      final session = await _authClient.appleLogin(
        idToken: credential.identityToken,
        authorizationCode: credential.authorizationCode,
        nonce: credential.nonce,
        state: credential.state,
      );
      await _persistSession(
        session,
        method: 'apple',
        generation: loginGeneration,
      );
      await _afterLogin();
      debugPrint('[Auth] apple login OK');
    } on AuthException catch (e) {
      authError.value = e.message;
    } on SocialLoginException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    } finally {
      isAuthenticating.value = false;
    }
  }

  Future<void> _afterLogin() async {
    await refreshEntitlement();
    await _refreshGatewayNodes();
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    appKitModal?.onModalConnect.unsubscribe(_onModalConnect);
    appKitModal?.onModalDisconnect.unsubscribe(_onModalDisconnect);
    appKitModal?.onModalError.unsubscribe(_onModalError);
    super.onClose();
  }

  /// Detects Seeker/Saga hardware so auth can skip Reown on Solana Mobile.
  Future<void> detectDevice() async {
    final detected = await detectSolanaMobileDevice();
    isSolanaMobileDevice.value = detected;
    PlatformCapabilities.isSolanaMobileDevice = detected;
  }

  /// Restores token + profile from secure storage before the UI loads.
  Future<void> loadPersistedSession() async {
    sessionReady.value = false;
    try {
      final stored = await sessions.restore();
      if (stored != null) {
        _applyStoredSession(stored);
        await sessions.ensureFresh();
        await refreshEntitlement();
        await refreshProfile();
        unawaited(refreshReferrals());
        unawaited(refreshRank());
        unawaited(refreshAccountOrgInvites());
        if (isAuthenticated) {
          debugPrint('[Auth] restored session for ${stored.walletAddress}');
        }
      } else {
        _applyToken(null);
        entitlement.value = EntitlementState.none;
      }
    } catch (e) {
      authError.value = e is AuthException
          ? e.message
          : 'Could not restore the secure session.';
    } finally {
      sessionReady.value = true;
    }
  }

  Future<void> initReown(BuildContext context) async {
    if (!usesReown) {
      reownReady.value = false;
      return;
    }
    if (!RuntimeConfig.hasReownProjectId) {
      authError.value = kReownProjectIdMissingMessage;
      reownReady.value = false;
      debugPrint('[Reown] init skipped — REOWN_PROJECT_ID not configured');
      return;
    }
    if (appKitModal != null) {
      reownReady.value = true;
      return;
    }

    ReownAppKitModalNetworks.removeSupportedNetworks('eip155');
    ReownAppKitModalNetworks.removeTestNetworks();

    final solanaChains = ReownAppKitModalNetworks.getAllSupportedNetworks(
      namespace: 'solana',
    );
    final solanaNamespaces = solanaChains.isEmpty
        ? null
        : {
            'solana': RequiredNamespace(
              chains: solanaChains.map((c) => c.chainId).toList(),
              methods: const ['solana_signMessage', 'solana_signTransaction'],
              events: const [],
            ),
          };

    appKitModal = ReownAppKitModal(
      context: context,
      projectId: RuntimeConfig.reownProjectId,
      logLevel: LogLevel.error,
      metadata: PairingMetadata(
        name: 'Erebrus VPN',
        description: 'Private, stealth-capable DePIN VPN',
        url: RuntimeConfig.erebrusSiteUrl,
        icons: [RuntimeConfig.erebrusSiteIcon],
        redirect: const Redirect(
          native: kErebrusNativeRedirect,
          universal: kErebrusUniversalRedirect,
          linkMode: false,
        ),
      ),
      optionalNamespaces: solanaNamespaces,
      featuresConfig: FeaturesConfig(
        showMainWallets: true,
        socials: const [
          AppKitSocialOption.Google,
          AppKitSocialOption.Apple,
          AppKitSocialOption.Email,
          AppKitSocialOption.X,
        ],
      ),
      disconnectOnDispose: false,
    );

    try {
      _walletLoginGeneration = await sessions.generation();
      final pid = RuntimeConfig.reownProjectId;
      final projectHint = pid.length > 8 ? '${pid.substring(0, 8)}…' : pid;
      final packageInfo = await PackageInfo.fromPlatform();
      final relayOrigin = packageInfo.packageName;
      debugPrint(
        '[Reown] initializing AppKit (project $projectHint, relay origin $relayOrigin, '
        'icon ${RuntimeConfig.erebrusSiteIcon})',
      );
      await appKitModal!.init();
      appKitModal!.onModalConnect.subscribe(_onModalConnect);
      appKitModal!.onModalDisconnect.subscribe(_onModalDisconnect);
      appKitModal!.onModalError.subscribe(_onModalError);

      DeepLinkHandler.bind(this);
      DeepLinkHandler.checkInitialLink();
      reownReady.value = true;
      debugPrint('[Reown] ready — wallets + social login available');

      if (appKitModal!.isConnected && !isAuthenticated) {
        await _authenticateConnectedWallet();
      }
    } catch (e) {
      debugPrint('[Reown] init failed: $e');
      authError.value = 'Wallet connect failed to start: $e';
      reownReady.value = false;
    }
  }

  /// Initializes desktop browser auth (deep-link listener only).
  void initDesktopAuth() {
    if (!usesWebLogin) return;
    DeepLinkHandler.bind(this);
    DeepLinkHandler.checkInitialLink();
    debugPrint(
      '[Auth] desktop web-login ready — origin ${RuntimeConfig.erebrusWebOrigin}',
    );
  }

  /// Opens MWA on Solana Mobile, browser on desktop, Reown modal on other mobile.
  Future<void> openSignIn() async {
    authError.value = null;
    if (isSolanaMobileDevice.value) {
      await signInWithSolanaMobile();
    } else if (usesWebLogin) {
      await openWebSignIn();
    } else {
      await openWalletModal();
    }
  }

  /// Opens erebrus.io in the system browser; PASETO returns via [kErebrusAuthCallback].
  Future<void> openWebSignIn() async {
    if (!_mayStartLogin()) return;
    if (!usesWebLogin) return;
    if (isAuthenticating.value || awaitingWebCallback.value) return;

    authError.value = null;
    awaitingWebCallback.value = true;
    try {
      _webLoginGeneration = await sessions.generation();
      final url = DesktopWebAuth.buildLoginUrl();
      debugPrint('[Auth] opening web login: $url');
      final uri = Uri.parse(url);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        awaitingWebCallback.value = false;
        authError.value =
            'Could not open the browser — check your default browser';
      }
    } catch (e) {
      awaitingWebCallback.value = false;
      authError.value = e.toString();
    }
  }

  /// Completes sign-in from pasted PASETO / callback URL (Postman-style fallback).
  Future<void> signInWithPastedCredential(String input) async {
    if (!_mayStartLogin()) return;
    isAuthenticating.value = true;
    awaitingWebCallback.value = false;
    authError.value = null;
    try {
      final loginGeneration = await sessions.generation();
      final callback = DesktopWebAuth.parseManualAuthInput(input);
      if (callback == null || callback.token.isEmpty) {
        authError.value =
            'Could not read a sign-in token — paste the PASETO or full callback URL';
        return;
      }

      var userId = callback.userId;
      var wallet = callback.walletAddress;
      final role = callback.role.isNotEmpty ? callback.role : 'user';

      // The session upgrade validates this legacy credential against the gateway.
      if (userId.isEmpty) userId = 'imported';
      if (wallet.isEmpty) wallet = 'imported';

      await _persistSession(
        AuthSession(
          token: callback.token,
          userId: userId,
          role: role,
          walletAddress: wallet,
        ),
        method: 'manual_paste',
        generation: loginGeneration,
      );
      DesktopWebAuth.clearPendingState();
      await refreshEntitlement();
      if (Get.isRegistered<GatewayController>()) {
        await Get.find<GatewayController>().refreshNodes();
      }
      debugPrint('[Auth] manual paste login OK');
    } on AuthException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    } finally {
      isAuthenticating.value = false;
    }
  }

  /// Reads clipboard and attempts [signInWithPastedCredential].
  Future<void> signInFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      authError.value =
          'Clipboard is empty — copy the PASETO from the browser first';
      return;
    }
    await signInWithPastedCredential(text);
  }

  /// Completes sign-in from `erebrusvpn://auth?token=…` (called by [DeepLinkHandler]).
  Future<void> handleWebAuthCallback(String url) async {
    if (!_mayStartLogin()) return;
    if (!usesWebLogin) return;

    awaitingWebCallback.value = false;
    isAuthenticating.value = true;
    authError.value = null;
    try {
      final loginGeneration = _webLoginGeneration;
      if (loginGeneration == null) {
        throw DesktopWebAuthException(
          'This sign-in was cancelled. Start sign-in again.',
        );
      }
      final callback = DesktopWebAuth.parseCallback(url);
      if (callback == null || !callback.isValid) {
        authError.value = 'Sign-in callback was incomplete — try again';
        return;
      }
      DesktopWebAuth.validateState(callback.state);

      await _persistSession(
        AuthSession(
          token: callback.token,
          userId: callback.userId,
          role: callback.role,
          walletAddress: callback.walletAddress,
        ),
        method: 'web',
        generation: loginGeneration,
      );
      DesktopWebAuth.clearPendingState();
      await refreshEntitlement();
      if (Get.isRegistered<GatewayController>()) {
        await Get.find<GatewayController>().refreshNodes();
      }
      debugPrint('[Auth] web login OK for ${callback.walletAddress}');
    } on DesktopWebAuthException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    } finally {
      isAuthenticating.value = false;
    }
  }

  Future<void> openWalletModal() async {
    if (!_mayStartLogin()) return;
    authError.value = null;
    if (appKitModal == null || !reownReady.value) {
      authError.value =
          'Wallet connect is still starting — try again in a moment';
      return;
    }
    _walletLoginGeneration = await sessions.generation();
    await appKitModal!.openModalView();
  }

  /// Mobile Wallet Adapter path — opens the native wallet selector on Seeker/Saga.
  Future<void> signInWithSolanaMobile() async {
    if (!_mayStartLogin()) return;
    if (!isSolanaMobileDevice.value) {
      authError.value =
          'Solana Mobile sign-in is only available on Seeker and Saga';
      return;
    }
    // Guard against a double-tap opening two wallet associations at once.
    if (isAuthenticating.value) return;

    isAuthenticating.value = true;
    authError.value = null;
    try {
      final loginGeneration = await sessions.generation();
      debugPrint('[MWA] gateway=${_authClient.baseUrl}');
      await _authClient.checkReachability();
      // One MWA association: authorize → fetch the challenge → sign it.
      var challengeId = '';
      final result = await mwaSignIn(
        storedAuthToken: _mwaAuthToken,
        challengeBuilder: (address, publicKey) async {
          final challenge = await _authClient.fetchAuthChallenge(
            walletAddress: address,
          );
          challengeId = challenge.challengeId;
          return challenge.message;
        },
      );
      _mwaAuthToken = result.authToken;

      final session = await _authClient.authenticate(
        challengeId: challengeId,
        signature: result.signature,
        publicKey: result.address,
      );
      await _persistSession(
        session,
        method: 'solana_mobile',
        generation: loginGeneration,
        mwaToken: result.authToken,
      );
      await refreshEntitlement();
      await _refreshGatewayNodes();
      debugPrint('[MWA] gateway auth OK for ${result.address}');
    } on MwaException catch (e) {
      authError.value = e.message;
    } on AuthException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    } finally {
      isAuthenticating.value = false;
    }
  }

  Future<void> signOut() async {
    if (_signingOut) return;
    _signingOut = true;
    _cancelProviderFlows();
    var confirmed = false;
    String? failure;
    try {
      confirmed = await sessions.logout();
    } catch (_) {
      failure = 'Could not clear secure storage. Please retry signing out.';
    } finally {
      await _clearSession(sessionExpired: false);
      _signingOut = false;
    }
    authError.value =
        failure ??
        (confirmed
            ? null
            : 'Signed out on this device. Remote session revocation is unconfirmed.');
  }

  /// Invalidates a stale session exactly once when concurrent authenticated
  /// requests all observe the same 401 response.
  Future<void> expireSession() {
    final existing = _sessionExpiryInFlight;
    if (existing != null) return existing;

    _cancelProviderFlows();
    late final Future<void> operation;
    operation = _clearSession(sessionExpired: true).whenComplete(() {
      if (identical(_sessionExpiryInFlight, operation)) {
        _sessionExpiryInFlight = null;
      }
    });
    _sessionExpiryInFlight = operation;
    return operation;
  }

  void _resetAccountData() {
    entitlementError.value = null;
    profileError.value = null;
    entitlement.value = EntitlementState.none;
    profileEmail.value = '';
    profileEmailVerified.value = false;
    profileName.value = '';
    profileChain.value = '';
    profileCreatedAt.value = null;
    referral.value = null;
    rank.value = null;
    accountOrgInvites.value = const [];
    accountOrgInvitesError.value = null;
    hasPendingDeletionRequest.value = false;
    deleteAccountError.value = null;
  }

  Future<void> _clearSession({required bool sessionExpired}) async {
    authError.value = sessionExpired
        ? 'Your session expired. Please sign in again.'
        : null;
    _resetAccountData();
    final mwaToken = _mwaAuthToken;
    _applyToken(null);
    _syncGatewayToken();
    _mwaAuthToken = null;
    unawaited(
      googleSignOut(),
    ); // best-effort; lets the chooser reappear next time
    walletAddress.value = '';
    userId.value = '';
    role.value = '';
    authMethod.value = '';
    if (Get.isRegistered<GatewayController>()) {
      await Get.find<GatewayController>().resetVpnLocalState();
    } else if (Get.isRegistered<VpnController>()) {
      await Get.find<VpnController>().resetLocalVpnData();
    }
    if (appKitModal?.isConnected == true) {
      await appKitModal?.disconnect();
    }
    await disconnectSolanaMobile(mwaToken);
    awaitingWebCallback.value = false;
    DesktopWebAuth.clearPendingState();
  }

  Future<void> refreshAccountOrgInvites() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      accountOrgInvites.value = const [];
      return;
    }
    isLoadingAccountOrgInvites.value = true;
    accountOrgInvitesError.value = null;
    try {
      accountOrgInvites.value = await _authClient.fetchAccountOrgInvites(token);
    } on AuthException catch (e) {
      accountOrgInvitesError.value = e.message;
    } catch (e) {
      accountOrgInvitesError.value = e.toString();
    } finally {
      isLoadingAccountOrgInvites.value = false;
    }
  }

  Future<void> acceptAccountOrgInvite(String orgId) async {
    if (!isAuthenticated) return;
    try {
      await _authClient.acceptAccountOrgInvite(_token!, orgId);
      accountOrgInvites.removeWhere((i) => i.orgId == orgId);
      unawaited(refreshAccountOrgInvites());
      if (Get.isRegistered<GatewayController>()) {
        unawaited(Get.find<GatewayController>().refreshNodes());
      }
    } on AuthException catch (e) {
      accountOrgInvitesError.value = e.message;
      rethrow;
    } catch (e) {
      accountOrgInvitesError.value = e.toString();
      rethrow;
    }
  }

  Future<void> declineAccountOrgInvite(String orgId) async {
    if (!isAuthenticated) return;
    try {
      await _authClient.declineAccountOrgInvite(_token!, orgId);
      accountOrgInvites.removeWhere((i) => i.orgId == orgId);
    } on AuthException catch (e) {
      accountOrgInvitesError.value = e.message;
      rethrow;
    } catch (e) {
      accountOrgInvitesError.value = e.toString();
      rethrow;
    }
  }

  Future<VpnOrg> createOrg({required String name, required String slug}) async {
    if (!isAuthenticated) throw AuthException('Sign in first');
    try {
      final org = await _authClient.createOrg(_token!, name: name, slug: slug);
      if (Get.isRegistered<GatewayController>()) {
        unawaited(Get.find<GatewayController>().refreshNodes());
      }
      return org;
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(e.toString());
    }
  }

  Future<String?> requestAccountDeletion() async {
    if (!isAuthenticated) {
      deleteAccountError.value = 'Sign in first';
      return null;
    }
    isDeletingAccount.value = true;
    deleteAccountError.value = null;
    try {
      final message = await _authClient.requestAccountDeletion(_token!);
      hasPendingDeletionRequest.value = true;
      return message;
    } on AuthException catch (e) {
      deleteAccountError.value = e.message;
      rethrow;
    } catch (e) {
      deleteAccountError.value = e.toString();
      rethrow;
    } finally {
      isDeletingAccount.value = false;
    }
  }

  Future<void> refreshProfile() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      profileEmail.value = '';
      profileEmailVerified.value = false;
      profileName.value = '';
      profileChain.value = '';
      profileCreatedAt.value = null;
      return;
    }
    isLoadingProfile.value = true;
    profileError.value = null;
    try {
      final profile = await _authClient.fetchProfile(token);
      _applyProfile(profile);
    } on AuthException catch (e) {
      profileError.value = e.message;
    } catch (e) {
      profileError.value = e.toString();
    } finally {
      isLoadingProfile.value = false;
    }
  }

  Future<void> updateDisplayName(String name) async {
    if (!isAuthenticated) return;
    isLoadingProfile.value = true;
    profileError.value = null;
    try {
      final profile = await _authClient.patchProfile(
        _token!,
        name: name.trim(),
      );
      _applyProfile(profile);
    } on AuthException catch (e) {
      profileError.value = e.message;
      rethrow;
    } finally {
      isLoadingProfile.value = false;
    }
  }

  Future<void> startEmailLink(String email) async {
    if (!isAuthenticated) {
      profileError.value = 'Sign in first';
      return;
    }
    isLinkingEmail.value = true;
    profileError.value = null;
    try {
      await _authClient.startEmailLink(_token!, email);
    } on AuthException catch (e) {
      profileError.value = e.message;
      rethrow;
    } finally {
      isLinkingEmail.value = false;
    }
  }

  Future<void> verifyEmailLink({
    required String email,
    required String code,
  }) async {
    if (!isAuthenticated) return;
    isLinkingEmail.value = true;
    profileError.value = null;
    try {
      final profile = await _authClient.verifyEmailLink(
        _token!,
        email: email,
        code: code,
      );
      _applyProfile(profile);
    } on AuthException catch (e) {
      profileError.value = e.message;
      rethrow;
    } finally {
      isLinkingEmail.value = false;
    }
  }

  /// Loads the referral summary (best-effort — the card just stays hidden on
  /// failure). The gateway allocates the invite code lazily on first access.
  Future<void> refreshReferrals() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      referral.value = null;
      return;
    }
    try {
      referral.value = await _authClient.fetchReferrals(token);
    } catch (e) {
      debugPrint('[Auth] referral summary load failed: $e');
    }
  }

  /// Loads the caller's XP standing (best-effort — the referrals card simply
  /// omits the XP stat on failure). Lifetime XP comes from `rank/me`, not the
  /// referral or profile responses.
  Future<void> refreshRank() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      rank.value = null;
      return;
    }
    try {
      rank.value = await _authClient.fetchRank(token);
    } catch (e) {
      debugPrint('[Auth] rank summary load failed: $e');
    }
  }

  /// Applies an invite code to this account (one referrer, ever). Throws
  /// [AuthException] with the gateway's message so the UI can surface it.
  Future<void> redeemReferralCode(String code) async {
    if (!isAuthenticated) return;
    isRedeemingReferral.value = true;
    try {
      final sum = await _authClient.redeemReferralCode(_token!, code);
      if (sum != null) {
        referral.value = sum;
      } else {
        await refreshReferrals();
      }
      // XP is awarded only once the caller qualifies (active org membership), so
      // it usually won't move at redeem time — refresh anyway so the displayed
      // balance reflects any immediate award.
      unawaited(refreshRank());
    } finally {
      isRedeemingReferral.value = false;
    }
  }

  void _applyProfile(UserProfile profile) {
    profileEmail.value = profile.email ?? '';
    profileEmailVerified.value = profile.emailVerified;
    profileName.value = profile.name ?? '';
    profileChain.value = profile.chain ?? '';
    profileCreatedAt.value = profile.createdAt;
    if (profile.walletAddress != null && profile.walletAddress!.isNotEmpty) {
      walletAddress.value = profile.walletAddress!;
    }
    if (profile.role.isNotEmpty) role.value = profile.role;
  }

  Future<void> refreshEntitlement() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      entitlement.value = EntitlementState.none;
      return;
    }
    isLoadingEntitlement.value = true;
    entitlementError.value = null;
    try {
      final ent = await _authClient.fetchSubscription(token);
      entitlement.value = ent;
      debugPrint(
        '[Auth] entitlement entitled=${ent.entitled} status=${ent.status} '
        'trialConsumed=${ent.trialConsumed} source=${ent.source}',
      );
    } on AuthException catch (e) {
      entitlementError.value = e.message;
    } catch (e) {
      entitlementError.value = e.toString();
    } finally {
      isLoadingEntitlement.value = false;
    }
  }

  Future<void> refreshNftEntitlement() async {
    if (!isAuthenticated) {
      entitlementError.value = 'Sign in first to verify your NFT';
      return;
    }
    if (!entitlement.value.nftGatingEnabled) {
      entitlementError.value = 'NFT gating is not enabled on this gateway';
      return;
    }

    isRefreshingNft.value = true;
    entitlementError.value = null;
    try {
      await _authClient.refreshNftEntitlement(_token!);
      await refreshEntitlement();
    } on AuthException catch (e) {
      entitlementError.value = e.message;
    } catch (e) {
      entitlementError.value = e.toString();
    } finally {
      isRefreshingNft.value = false;
    }
  }

  void _applyToken(String? token) {
    _token = token;
    sessionActive.value = token != null && token.isNotEmpty;
  }

  Future<void> _persistSession(
    AuthSession session, {
    required String method,
    required int generation,
    String? mwaToken,
  }) async {
    final previousUser = userId.value;
    final confirmed = await sessions.install(
      StoredAuthSession(
        credentials: session,
        authMethod: method,
        mwaAuthToken: mwaToken,
      ),
      generation: generation,
    );
    if (previousUser.isNotEmpty &&
        previousUser != session.userId &&
        Get.isRegistered<GatewayController>()) {
      await Get.find<GatewayController>().resetVpnLocalState();
    }
    if (!confirmed) {
      authError.value =
          'Signed in. Previous session revocation is unconfirmed.';
    }
    // A browser callback is a legacy bearer handoff only. Never copy a webapp's
    // refresh credential into this independent native app's session.
    await sessions.ensureFresh();
    unawaited(refreshProfile());
    unawaited(refreshReferrals());
    unawaited(refreshRank());
    unawaited(refreshAccountOrgInvites());
  }

  void _syncGatewayToken() {
    if (Get.isRegistered<GatewayController>()) {
      Get.find<GatewayController>().setBearerToken(_token);
    }
  }

  Future<void> _refreshGatewayNodes() async {
    if (Get.isRegistered<GatewayController>()) {
      await Get.find<GatewayController>().refreshNodes();
    }
  }

  void _onModalConnect(ModalConnect? event) {
    if (event != null) _authenticateConnectedWallet();
  }

  void _onModalDisconnect(ModalDisconnect? event) {}

  void _onModalError(ModalError? event) {
    final message = event?.message;
    if (message == null || message.isEmpty) return;
    if (message.toLowerCase().contains('origin not allowed')) {
      authError.value = reownOriginNotAllowedMessage(kErebrusBundleId);
      return;
    }
    authError.value = message;
  }

  Future<void> _authenticateConnectedWallet() async {
    if (!_mayStartLogin() || isAuthenticating.value) return;
    final loginGeneration = _walletLoginGeneration;
    if (loginGeneration == null) return;
    final modal = appKitModal;
    if (modal == null || !modal.isConnected) return;

    isAuthenticating.value = true;
    authError.value = null;
    try {
      final address = await _solanaAddress(modal);
      if (address == null || address.isEmpty) {
        authError.value =
            'Connect a Solana wallet (Phantom, Solflare, etc.). '
            'For email sign-in, use Continue with Email on the login screen — '
            'the wallet modal email option does not sign you into Erebrus.';
        return;
      }
      final challenge = await _authClient.fetchAuthChallenge(
        walletAddress: address,
      );
      final signature = await _signChallenge(modal, address, challenge.message);
      final session = await _authClient.authenticate(
        challengeId: challenge.challengeId,
        signature: signature,
        publicKey: address,
      );
      await _persistSession(
        session,
        method: 'reown',
        generation: loginGeneration,
      );
      await refreshEntitlement();
      await _refreshGatewayNodes();
      if (modal.isOpen) modal.closeModal();
      debugPrint('[Reown] gateway auth OK for $address');
    } on AuthException catch (e) {
      authError.value = e.message;
    } catch (e) {
      authError.value = e.toString();
    } finally {
      isAuthenticating.value = false;
    }
  }

  Future<String?> _solanaAddress(ReownAppKitModal modal) async {
    final chainId = modal.selectedChain?.chainId ?? '';
    if (!chainId.startsWith('solana:')) {
      final solChains = ReownAppKitModalNetworks.getAllSupportedNetworks(
        namespace: 'solana',
      );
      if (solChains.isNotEmpty) {
        await modal.selectChain(solChains.first);
      }
    }
    final selected = modal.selectedChain?.chainId ?? '';
    if (!selected.startsWith('solana:')) return null;
    return modal.session?.getAddress('solana');
  }

  Future<String> _signChallenge(
    ReownAppKitModal modal,
    String address,
    String message,
  ) async {
    final chainId = modal.selectedChain!.chainId;
    final messageBase58 = base58.encode(utf8.encode(message));

    final response = await modal.request(
      topic: modal.session!.topic,
      chainId: chainId,
      request: SessionRequestParams(
        method: 'solana_signMessage',
        params: {'pubkey': address, 'message': messageBase58},
      ),
    );

    return _signatureToTransmittable(response);
  }

  String _signatureToTransmittable(dynamic response) {
    if (response is String) return response;
    if (response is Map) {
      final sig = ReownCoreUtils.recursiveSearchForMapKey(
        Map<String, dynamic>.from(response),
        'signature',
      );
      if (sig is String) return sig;
    }
    if (response is List && response.isNotEmpty) {
      return _signatureToTransmittable(response.first);
    }
    throw AuthException('Wallet returned an unreadable signature');
  }
}
