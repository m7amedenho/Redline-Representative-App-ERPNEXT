// Unit tests for ErpService against a fake HTTP adapter + AuthService's
// fake secure store — no real network, no real platform channel.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:red_erp/services/auth_service.dart';
import 'package:red_erp/services/erp_service.dart';
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

void main() {
  late _FakeSecureStore store;

  setUp(() async {
    store = _FakeSecureStore();
    AuthService.debugOverrideStore(store);
    await store.write('red_erp_domain', 'https://company.redtch.com');
    await store.write('red_erp_access_token', 'AT-current');
    await store.write('red_erp_refresh_token', 'RT-current');
  });

  test('createDoc posts to /api/resource/<DocType> and unwraps {data: ...}', () async {
    final dio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        expect(options.method, 'POST');
        expect(options.path, '/api/resource/Sales Order');
        expect(options.headers['Authorization'], 'Bearer AT-current');
        return _jsonResponse({
          'data': {'name': 'SO-0001', 'customer': 'ACME'},
        }, 200);
      });
    ErpService.debugOverrideDio(dio);

    final doc = await ErpService.createDoc('Sales Order', {'customer': 'ACME'});

    expect(doc['name'], 'SO-0001');
  });

  test('getList sends JSON-encoded filters/fields and unwraps {data: [...]}', () async {
    final dio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        expect(options.method, 'GET');
        expect(options.path, '/api/resource/Customer');
        expect(
          options.queryParameters['filters'],
          jsonEncode([
            ['customer_name', 'like', '%نور%'],
          ]),
        );
        return _jsonResponse({
          'data': [
            {'name': 'CUST-01', 'customer_name': 'سوبر ماركت النور'},
          ],
        }, 200);
      });
    ErpService.debugOverrideDio(dio);

    final list = await ErpService.getList(
      'Customer',
      filters: [
        ['customer_name', 'like', '%نور%'],
      ],
      fields: ['name', 'customer_name'],
    );

    expect(list, hasLength(1));
    expect(list.first['customer_name'], 'سوبر ماركت النور');
  });

  test('callMethod unwraps a {"message": {...}} RPC envelope', () async {
    final dio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        expect(
          options.path,
          '/api/method/erpnext.accounts.party.get_party_details',
        );
        expect(options.queryParameters['party'], 'CUST-01');
        return _jsonResponse({
          'message': {'price_list': 'Standard Selling'},
        }, 200);
      });
    ErpService.debugOverrideDio(dio);

    final result = await ErpService.getPartyDetails(party: 'CUST-01');

    expect(result['price_list'], 'Standard Selling');
  });

  test('callMethodList returns a bare JSON array payload', () async {
    final dio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        expect(
          options.path,
          '/api/method/erpnext.accounts.doctype.payment_entry.payment_entry.get_outstanding_reference_documents',
        );
        final args = jsonDecode(options.queryParameters['args'] as String);
        expect(args['party'], 'CUST-01');
        expect(args['party_type'], 'Customer');
        return _jsonResponse({
          'message': [
            {'voucher_no': 'SINV-0001', 'outstanding_amount': 500},
          ],
        }, 200);
      });
    ErpService.debugOverrideDio(dio);

    final result = await ErpService.getOutstandingReferenceDocuments(
      party: 'CUST-01',
      company: 'My Company',
    );

    expect(result, hasLength(1));
    expect(result.first['voucher_no'], 'SINV-0001');
  });

  test('make_in_transit_stock_entry sends both required params', () async {
    final dio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        expect(options.queryParameters['source_name'], 'MREQ-0001');
        expect(options.queryParameters['in_transit_warehouse'], 'Transit - C');
        return _jsonResponse({
          'message': {'name': 'STE-0001'},
        }, 200);
      });
    ErpService.debugOverrideDio(dio);

    final doc = await ErpService.makeInTransitStockEntry(
      sourceName: 'MREQ-0001',
      inTransitWarehouse: 'Transit - C',
    );

    expect(doc['name'], 'STE-0001');
  });

  test('a 401 triggers one silent refresh + retry, then succeeds', () async {
    var refreshCalled = false;
    var attempt = 0;

    final authDio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        refreshCalled = true;
        return _jsonResponse({
          'access_token': 'AT-new',
          'refresh_token': 'RT-new',
        }, 200);
      });
    AuthService.debugOverrideDio(authDio);

    final erpDio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        attempt++;
        if (attempt == 1) {
          expect(options.headers['Authorization'], 'Bearer AT-current');
          return _jsonResponse({'message': 'Token expired'}, 401);
        }
        expect(options.headers['Authorization'], 'Bearer AT-new');
        return _jsonResponse({
          'data': {'name': 'CUST-01'},
        }, 200);
      });
    ErpService.debugOverrideDio(erpDio);

    final doc = await ErpService.getDoc('Customer', 'CUST-01');

    expect(refreshCalled, isTrue);
    expect(attempt, 2);
    expect(doc['name'], 'CUST-01');
  });

  test('a 401 that survives the refresh throws a sessionExpired error', () async {
    final authDio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        return _jsonResponse({'message': 'Invalid refresh token'}, 401);
      });
    AuthService.debugOverrideDio(authDio);

    final erpDio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        return _jsonResponse({'message': 'Token expired'}, 401);
      });
    ErpService.debugOverrideDio(erpDio);

    await expectLater(
      ErpService.getDoc('Customer', 'CUST-01'),
      throwsA(
        isA<ErpException>().having(
          (e) => e.sessionExpired,
          'sessionExpired',
          true,
        ),
      ),
    );
  });

  test('getCustomerCreditStatus swallows any failure and returns null', () async {
    final dio = Dio(BaseOptions())
      ..httpClientAdapter = _FakeAdapter((options) {
        return _jsonResponse({'message': 'Not Found'}, 404);
      });
    ErpService.debugOverrideDio(dio);

    final result = await ErpService.getCustomerCreditStatus('CUST-01');

    expect(result, isNull);
  });
}
