/// Gateway credentials are opaque (including PASETO); expiry comes from metadata.
class AuthSession {
  const AuthSession({
    required this.token,
    required this.userId,
    required this.role,
    required this.walletAddress,
    this.tokenType = 'Bearer',
    this.expiresAt,
    this.expiresIn,
    this.refreshToken,
    this.refreshExpiresAt,
    this.refreshExpiresIn,
    this.sessionId,
  });

  final String token;
  final String userId;
  final String role;
  final String walletAddress;
  final String tokenType;
  final DateTime? expiresAt;
  final int? expiresIn;
  final String? refreshToken;
  final DateTime? refreshExpiresAt;
  final int? refreshExpiresIn;
  final String? sessionId;

  factory AuthSession.fromJson(
    Map<String, dynamic> json, {
    DateTime? now,
    String walletAddress = '',
  }) {
    final received = (now ?? DateTime.now()).toUtc();
    final accessSeconds = _seconds(json['expires_in']);
    final refreshSeconds = _seconds(json['refresh_expires_in']);
    return AuthSession(
      token: (json['access_token'] ?? json['token'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      role: (json['role'] ?? 'user').toString(),
      walletAddress: (json['wallet_address'] ?? walletAddress).toString(),
      tokenType: (json['token_type'] ?? 'Bearer').toString(),
      expiresAt:
          _expiry(json['expires_at']) ??
          (accessSeconds == null
              ? null
              : received.add(Duration(seconds: accessSeconds))),
      expiresIn: accessSeconds,
      refreshToken: json['refresh_token']?.toString(),
      refreshExpiresAt:
          _expiry(json['refresh_expires_at']) ??
          (refreshSeconds == null
              ? null
              : received.add(Duration(seconds: refreshSeconds))),
      refreshExpiresIn: refreshSeconds,
      sessionId: json['session_id']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'access_token': token,
    'user_id': userId,
    'role': role,
    'wallet_address': walletAddress,
    'token_type': tokenType,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'expires_in': expiresIn,
    'refresh_token': refreshToken,
    'refresh_expires_at': refreshExpiresAt?.toUtc().toIso8601String(),
    'refresh_expires_in': refreshExpiresIn,
    'session_id': sessionId,
  };

  bool get isRefreshable => refreshToken?.isNotEmpty == true;
  bool get isComplete =>
      token.isNotEmpty &&
      isRefreshable &&
      expiresAt != null &&
      refreshExpiresAt != null &&
      sessionId?.isNotEmpty == true &&
      userId.isNotEmpty;

  static int? _seconds(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value');
  static DateTime? _expiry(dynamic value) {
    if (value == null) return null;
    final number = num.tryParse('$value');
    if (number != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        (number * 1000).round(),
        isUtc: true,
      );
    }
    return DateTime.tryParse('$value')?.toUtc();
  }
}
