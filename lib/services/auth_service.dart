import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'secure_store.dart';

/// Belt-and-braces on top of Dio's own connect/receive timeouts: on some
/// Android networks (VPNs, captive portals, firewalls that black-hole
/// packets instead of rejecting them) the underlying OS socket connect can
/// hang far longer than Dio's configured timeouts actually enforce — a
/// known `dart:io`/Dio limitation, not something fixable from BaseOptions
/// alone. Wrapping every awaited call in `.timeout()` guarantees the
/// Future the UI is awaiting always settles, so the app can never look
/// permanently frozen no matter what the network layer does underneath.
const _hardNetworkTimeout = Duration(seconds: 25);

/// Friendly, Arabic-only error meant to be shown directly to the user.
/// Never surface a raw exception/stack trace in the UI.
class AuthException implements Exception {
  const AuthException(
    this.message, {
    this.serverRejected = false,
    this.accessRestricted = false,
  });

  final String message;

  /// True only when the server explicitly rejected the request (401/403 or
  /// a PermissionError body) — meaning the stored tokens are actually
  /// invalid and should be cleared. False for network/timeout failures,
  /// where the stored refresh token may still be good and worth retrying.
  final bool serverRejected;

  /// True specifically for the licensing/seat-access `PermissionError`
  /// `mobile_control` throws when this account isn't allowed to use the
  /// mobile app right now (see `red_license`'s `License User Access` on
  /// the server). The caller should show a dedicated full-screen "access
  /// restricted" state instead of just an inline form error — nothing
  /// else about the app (not even the username) should render for an
  /// account in this state.
  final bool accessRestricted;

  @override
  String toString() => message;
}

class AuthResult {
  const AuthResult({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// Talks to the `mobile_control` auth endpoints (login/refresh/me/logout)
/// and persists tokens via [SecureStore] (backed by secure storage).
///
/// These endpoints are NOT in the ERPNext/Frappe OpenAPI specs (mobile_control
/// is a custom app) — names/params were given directly. A few wire-format
/// details weren't specified and are handled defensively; see
/// docs/API_INTEGRATION_NOTES.md for exactly what's confirmed vs assumed.
class AuthService {
  AuthService._();

  static const _domainKey = 'red_erp_domain';
  static const _accessTokenKey = 'red_erp_access_token';
  static const _refreshTokenKey = 'red_erp_refresh_token';
  static const _biometricEnabledKey = 'red_erp_biometric_enabled';

  static SecureStore _store = const RealSecureStore();
  static Dio? _dio;

  /// Swaps in a test double. Only for widget/unit tests.
  @visibleForTesting
  static void debugOverrideStore(SecureStore store) => _store = store;

  static Dio _client(String baseUrl) {
    final dio = _dio ??= Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: const {'Accept': 'application/json'},
        // Let us inspect 4xx bodies ourselves instead of Dio throwing before
        // we get a chance to read the error shape.
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    dio.options.baseUrl = baseUrl;
    return dio;
  }

  /// Swaps in a test double. Only for widget/unit tests.
  @visibleForTesting
  static void debugOverrideDio(Dio dio) => _dio = dio;

  @visibleForTesting
  static String normalizeDomain(String raw) {
    var domain = raw.trim();
    while (domain.endsWith('/')) {
      domain = domain.substring(0, domain.length - 1);
    }
    if (!domain.startsWith('http://') && !domain.startsWith('https://')) {
      domain = 'https://$domain';
    }
    return domain;
  }

  static Future<AuthResult> login({
    required String domain,
    required String username,
    required String password,
  }) async {
    final baseUrl = normalizeDomain(domain);
    final dio = _client(baseUrl);

    try {
      final response = await dio
          .post(
            '/api/method/mobile_control.api.api_auth.login',
            data: {'username': username, 'password': password},
          )
          .timeout(_hardNetworkTimeout);

      if (response.statusCode != 200) {
        throw _mapErrorResponse(response);
      }

      final payload = _unwrap(response.data);
      final accessToken = payload['access_token'] as String?;
      final refreshToken = payload['refresh_token'] as String?;

      if (accessToken == null || refreshToken == null) {
        throw const AuthException('تعذر إتمام تسجيل الدخول، حاول مرة أخرى.');
      }

      await _store.write(_domainKey, baseUrl);
      await _store.write(_accessTokenKey, accessToken);
      await _store.write(_refreshTokenKey, refreshToken);

      return AuthResult(accessToken: accessToken, refreshToken: refreshToken);
    } on DioException catch (e) {
      throw _mapDioException(e);
    } on TimeoutException {
      throw const AuthException(
        'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
      );
    }
  }

  /// Uses the stored refresh token to get a new access token, without
  /// asking for a password again. Call this only after the caller has
  /// already gated it behind biometrics (see SplashScreen).
  static Future<AuthResult> refreshSession() async {
    final domain = await _store.read(_domainKey);
    final refreshToken = await _store.read(_refreshTokenKey);

    if (domain == null || refreshToken == null) {
      throw const AuthException('لا توجد جلسة محفوظة.', serverRejected: true);
    }

    final dio = _client(domain);

    try {
      final response = await dio
          .post(
            '/api/method/mobile_control.api.api_auth.refresh_token',
            data: {'refresh_token': refreshToken},
          )
          .timeout(_hardNetworkTimeout);

      if (response.statusCode != 200) {
        throw _mapErrorResponse(response);
      }

      final payload = _unwrap(response.data);
      final newAccessToken = payload['access_token'] as String?;
      final newRefreshToken =
          payload['refresh_token'] as String? ?? refreshToken;

      if (newAccessToken == null) {
        throw const AuthException(
          'انتهت صلاحية الجلسة، برجاء تسجيل الدخول مرة أخرى.',
          serverRejected: true,
        );
      }

      await _store.write(_accessTokenKey, newAccessToken);
      await _store.write(_refreshTokenKey, newRefreshToken);

      return AuthResult(
        accessToken: newAccessToken,
        refreshToken: newRefreshToken,
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    } on TimeoutException {
      throw const AuthException(
        'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
      );
    }
  }

  /// `mobile_control.api.api_auth.me` — current user's profile/roles.
  /// Confirmed response shape (verified against the real server): `name`,
  /// `user`, `full_name`, `roles` (a list of strings, every role assigned
  /// to this user — includes the `WF - *` workflow-approval roles), and
  /// `permissions` (a list of per-DocType CRUD flags for a handful of
  /// DocTypes). See docs/API_INTEGRATION_NOTES.md.
  static Future<Map<String, dynamic>> me() async {
    final domain = await _store.read(_domainKey);
    final accessToken = await _store.read(_accessTokenKey);

    if (domain == null || accessToken == null) {
      throw const AuthException('لا توجد جلسة محفوظة.', serverRejected: true);
    }

    final dio = _client(domain);

    try {
      final response = await dio
          .get(
            '/api/method/mobile_control.api.api_auth.me',
            options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
          )
          .timeout(_hardNetworkTimeout);

      if (response.statusCode != 200) {
        throw _mapErrorResponse(response);
      }

      return _unwrap(response.data);
    } on DioException catch (e) {
      throw _mapDioException(e);
    } on TimeoutException {
      throw const AuthException(
        'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
      );
    }
  }

  static String? _cachedUserId;
  static List<String>? _cachedRoles;

  /// The current user's identifier (email/username) — used to filter
  /// records down to "belongs to this rep" (e.g. `Customer.account_manager`).
  /// Resolved from `me()` using the same fallback chain as everywhere else
  /// in the app that needs it (`email` → `user` → `name`), and cached for
  /// the rest of the session since it can't change without a logout.
  /// Returns null (never throws) if it can't be resolved — callers should
  /// fail open (show unfiltered data) rather than block on it.
  static Future<String?> currentUserId() async {
    final cached = _cachedUserId;
    if (cached != null) return cached;
    try {
      final me = await AuthService.me();
      final id = (me['email'] ?? me['user'] ?? me['name'])?.toString();
      if (id != null && id.isNotEmpty) _cachedUserId = id;
      return _cachedUserId;
    } catch (_) {
      return null;
    }
  }

  /// The current user's full role list — confirmed present in `me()`'s
  /// response as `roles` (see doc comment above). Cached for the session.
  /// Returns an empty list (never throws) on any failure.
  static Future<List<String>> currentUserRoles() async {
    final cached = _cachedRoles;
    if (cached != null) return cached;
    try {
      final me = await AuthService.me();
      final roles = me['roles'];
      if (roles is List) {
        _cachedRoles = roles.map((r) => r.toString()).toList();
      }
      return _cachedRoles ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Highest discount-approval tier the current user holds, from a fixed
  /// priority order (highest first) — used to look up the matching row in
  /// an item's `custom_role_discount_limits`. Null if the user holds none
  /// of these roles (e.g. an account with no discount authority at all).
  /// Deliberately excludes "WF - Sales Rep" — discount editing (both the
  /// per-item limit and the document-level extra discount) is a manager-only
  /// capability; a rep must never see the control at all, not even bounded
  /// to a small limit.
  static String? resolveDiscountTier(List<String> roles) {
    const tierOrder = ['WF - General Manager', 'WF - Region Manager'];
    for (final tier in tierOrder) {
      if (roles.contains(tier)) return tier;
    }
    return null;
  }

  static Future<void> logout() async {
    final domain = await _store.read(_domainKey);
    final accessToken = await _store.read(_accessTokenKey);

    if (domain != null && accessToken != null) {
      try {
        final dio = _client(domain);
        await dio
            .post(
              '/api/method/mobile_control.api.api_auth.logout',
              options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
            )
            .timeout(_hardNetworkTimeout);
      } catch (_) {
        // Best-effort — the local session is cleared regardless of whether
        // the server call succeeds, so the user isn't stuck logged in on
        // this device just because the network dropped.
      }
    }

    await clearSession();
  }

  static Future<void> clearSession() async {
    await _store.delete(_domainKey);
    await _store.delete(_accessTokenKey);
    await _store.delete(_refreshTokenKey);
    _cachedUserId = null;
    _cachedRoles = null;
  }

  /// Whether a refresh token is on disk — the splash screen uses this to
  /// decide between onboarding and the biometric-gated silent refresh.
  static Future<bool> hasStoredSession() async {
    final refreshToken = await _store.read(_refreshTokenKey);
    return refreshToken != null;
  }

  /// Whether the biometric gate on silent-refresh should run. Defaults to
  /// on (matches the original behavior) until the user explicitly turns it
  /// off from the account screen.
  static Future<bool> isBiometricEnabled() async {
    final stored = await _store.read(_biometricEnabledKey);
    return stored != 'false';
  }

  static Future<void> setBiometricEnabled(bool enabled) =>
      _store.write(_biometricEnabledKey, enabled ? 'true' : 'false');

  static Future<String?> currentAccessToken() => _store.read(_accessTokenKey);

  static Future<String?> currentDomain() => _store.read(_domainKey);

  /// mobile_control's methods were specified with a flat response body
  /// (`{access_token, refresh_token, ...}`), but standard Frappe
  /// `@frappe.whitelist()` methods normally wrap their return value in a
  /// `{"message": ...}` envelope. Handles both so we're not stuck guessing
  /// which one the real server does — flagged in the integration notes.
  static Map<String, dynamic> _unwrap(dynamic data) {
    dynamic parsed = data;
    if (parsed is String) {
      try {
        parsed = jsonDecode(parsed);
      } catch (_) {
        return const <String, dynamic>{};
      }
    }

    if (parsed is Map) {
      final map = Map<String, dynamic>.from(parsed);
      if (map.containsKey('access_token') || map.containsKey('refresh_token')) {
        return map;
      }
      final message = map['message'];
      if (message is Map) {
        return Map<String, dynamic>.from(message);
      }
    }

    return const <String, dynamic>{};
  }

  static AuthException _mapErrorResponse(Response response) {
    final data = response.data;
    if (data is Map) {
      final excType = data['exc_type']?.toString() ?? '';
      final exception = data['exception']?.toString() ?? '';
      if (excType == 'PermissionError' ||
          exception.contains('PermissionError')) {
        return const AuthException(
          'حسابك غير مصرح له باستخدام تطبيق الموبايل حاليًا. تواصل مع الإدارة.',
          serverRejected: true,
          accessRestricted: true,
        );
      }
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      return const AuthException(
        'بيانات الدخول غير صحيحة.',
        serverRejected: true,
      );
    }

    return const AuthException(
      'حدث خطأ غير متوقع، حاول مرة أخرى لاحقًا.',
      serverRejected: true,
    );
  }

  static AuthException _mapDioException(DioException e) {
    if (e.response != null) {
      return _mapErrorResponse(e.response!);
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const AuthException(
          'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
        );
      case DioExceptionType.connectionError:
        return const AuthException(
          'تعذر الاتصال بالسيرفر، تأكد من صحة الدومين واتصالك بالإنترنت.',
        );
      default:
        return const AuthException('حدث خطأ غير متوقع، حاول مرة أخرى لاحقًا.');
    }
  }
}
