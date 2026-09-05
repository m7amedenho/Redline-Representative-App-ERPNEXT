// Unit tests for AuthService against a fake HTTP adapter + in-memory
// secure store — no real network, no real platform channel.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:red_erp/services/auth_service.dart';
import 'package:red_erp/services/secure_store.dart';

class _FakeSecureStore implements SecureStore {
  final Map<String, String> _values = {};

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Routes requests to a handler that decides the fake HTTP response purely
/// from the request path — good enough for these endpoint-shape tests.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options);
  }
}

ResponseBody _jsonResponse(Object body, int statusCode) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void _useFakeDio(ResponseBody Function(RequestOptions options) handler) {
  final dio = Dio(BaseOptions())..httpClientAdapter = _FakeAdapter(handler);
  AuthService.debugOverrideDio(dio);
}

void main() {
  late _FakeSecureStore store;

  setUp(() {
    store = _FakeSecureStore();
    AuthService.debugOverrideStore(store);
  });

  group('normalizeDomain', () {
    test('adds https:// when no protocol given', () {
      expect(
        AuthService.normalizeDomain('company.redtch.com'),
        'https://company.redtch.com',
      );
    });

    test('keeps an explicit http:// as-is', () {
      expect(
        AuthService.normalizeDomain('http://company.redtch.com'),
        'http://company.redtch.com',
      );
    });

    test('strips a trailing slash', () {
      expect(
        AuthService.normalizeDomain('https://company.redtch.com/'),
        'https://company.redtch.com',
      );
    });
  });

  group('login', () {
    test('stores tokens on success (flat response body)', () async {
      _useFakeDio((options) {
        expect(options.path, '/api/method/mobile_control.api.api_auth.login');
        return _jsonResponse({
          'access_token': 'AT-1',
          'refresh_token': 'RT-1',
        }, 200);
      });

      final result = await AuthService.login(
        domain: 'company.redtch.com',
        username: 'red',
        password: '1234',
      );

      expect(result.accessToken, 'AT-1');
      expect(result.refreshToken, 'RT-1');
      expect(await store.read('red_erp_access_token'), 'AT-1');
      expect(await store.read('red_erp_refresh_token'), 'RT-1');
      expect(await store.read('red_erp_domain'), 'https://company.redtch.com');
    });

    test('also accepts a Frappe-style {"message": {...}} envelope', () async {
      _useFakeDio((options) {
        return _jsonResponse({
          'message': {'access_token': 'AT-2', 'refresh_token': 'RT-2'},
        }, 200);
      });

      final result = await AuthService.login(
        domain: 'company.redtch.com',
        username: 'red',
        password: '1234',
      );

      expect(result.accessToken, 'AT-2');
      expect(result.refreshToken, 'RT-2');
    });

    test('maps PermissionError to the friendly Arabic message', () async {
      _useFakeDio((options) {
        return _jsonResponse({
          'exc_type': 'PermissionError',
          'exception':
              'frappe.exceptions.PermissionError: Not allowed to use mobile app',
        }, 403);
      });

      await expectLater(
        AuthService.login(
          domain: 'company.redtch.com',
          username: 'red',
          password: '1234',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.serverRejected, 'serverRejected', true)
              .having((e) => e.message, 'message', contains('غير مفعّل')),
        ),
      );
    });

    test('maps a plain 401 to invalid-credentials message', () async {
      _useFakeDio(
        (options) => _jsonResponse({'message': 'Invalid Login'}, 401),
      );

      await expectLater(
        AuthService.login(
          domain: 'company.redtch.com',
          username: 'red',
          password: 'wrong',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            'بيانات الدخول غير صحيحة.',
          ),
        ),
      );
    });

    test(
      'maps a connection error to a network message, not server-rejected',
      () async {
        final dio = Dio(BaseOptions())
          ..httpClientAdapter = _FakeAdapter((options) {
            throw DioException.connectionError(
              requestOptions: options,
              reason: 'Failed host lookup',
            );
          });
        AuthService.debugOverrideDio(dio);

        await expectLater(
          AuthService.login(
            domain: 'company.redtch.com',
            username: 'red',
            password: '1234',
          ),
          throwsA(
            isA<AuthException>().having(
              (e) => e.serverRejected,
              'serverRejected',
              false,
            ),
          ),
        );
      },
    );
  });

  group('refreshSession', () {
    test('throws when there is nothing stored yet', () async {
      await expectLater(
        AuthService.refreshSession(),
        throwsA(
          isA<AuthException>().having(
            (e) => e.serverRejected,
            'serverRejected',
            true,
          ),
        ),
      );
    });

    test('rotates tokens on success', () async {
      await store.write('red_erp_domain', 'https://company.redtch.com');
      await store.write('red_erp_refresh_token', 'RT-old');

      _useFakeDio((options) {
        expect(
          options.path,
          '/api/method/mobile_control.api.api_auth.refresh_token',
        );
        return _jsonResponse({
          'access_token': 'AT-new',
          'refresh_token': 'RT-new',
        }, 200);
      });

      final result = await AuthService.refreshSession();

      expect(result.accessToken, 'AT-new');
      expect(await store.read('red_erp_access_token'), 'AT-new');
      expect(await store.read('red_erp_refresh_token'), 'RT-new');
    });
  });

  group('hasStoredSession', () {
    test(
      'false with nothing stored, true once a refresh token exists',
      () async {
        expect(await AuthService.hasStoredSession(), isFalse);
        await store.write('red_erp_refresh_token', 'RT-1');
        expect(await AuthService.hasStoredSession(), isTrue);
      },
    );
  });

  group('logout', () {
    test('clears local storage even if the network call fails', () async {
      await store.write('red_erp_domain', 'https://company.redtch.com');
      await store.write('red_erp_access_token', 'AT-1');
      await store.write('red_erp_refresh_token', 'RT-1');

      final dio = Dio(BaseOptions())
        ..httpClientAdapter = _FakeAdapter((options) {
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'offline',
          );
        });
      AuthService.debugOverrideDio(dio);

      await AuthService.logout();

      expect(await store.read('red_erp_domain'), isNull);
      expect(await store.read('red_erp_access_token'), isNull);
      expect(await store.read('red_erp_refresh_token'), isNull);
    });
  });
}
