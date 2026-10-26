class AuthException implements Exception {
  AuthException(this.message, {this.statusCode, this.code, this.retryAt});
  final String message;
  final int? statusCode;
  final String? code;
  final DateTime? retryAt;

  bool get isSessionExpired => const {
    'REFRESH_TOKEN_INVALID',
    'REFRESH_TOKEN_REUSED',
    'SESSION_REVOKED',
  }.contains(code);

  @override
  String toString() => message;
}
