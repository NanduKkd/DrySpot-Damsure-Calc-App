import 'dart:io';
import 'dart:convert';

import 'package:app_client/src/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('normalizeServerUrl accepts a root server URL', () {
    expect(
      ApiService.normalizeServerUrl('http://192.168.1.25:3000'),
      'http://192.168.1.25:3000',
    );
  });

  test('normalizeServerUrl strips a trailing /api segment', () {
    expect(
      ApiService.normalizeServerUrl('http://192.168.1.25:3000/api/'),
      'http://192.168.1.25:3000',
    );
  });

  test('setServerUrl persists the normalized server URL', () async {
    final apiService = ApiService(serverUrl: 'http://localhost:3000');

    await apiService.setServerUrl('http://10.0.2.2:3000/api');

    expect(apiService.serverUrl, 'http://10.0.2.2:3000');
    expect(apiService.baseUrl, 'http://10.0.2.2:3000/api');

    final reloadedService = ApiService(serverUrl: 'http://localhost:3000');
    await reloadedService.loadServerUrl();

    expect(reloadedService.serverUrl, 'http://10.0.2.2:3000');
    expect(reloadedService.baseUrl, 'http://10.0.2.2:3000/api');
  });

  test(
    'uploadWarranty surfaces plain text server errors without a FormatException',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/warranty/upload');

        await request.drain<void>();
        request.response.statusCode = HttpStatus.badRequest;
        request.response.headers.contentType = ContentType.text;
        request.response.write('Warranty upload rejected');
        await request.response.close();
      });

      final tempDir = await Directory.systemTemp.createTemp('api-service-test');
      addTearDown(() => tempDir.delete(recursive: true));

      final pdfFile = File('${tempDir.path}/sample.pdf');
      await pdfFile.writeAsBytes('%PDF-1.4\n%dummy\n'.codeUnits);

      final apiService = ApiService(
        serverUrl: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => apiService.uploadWarranty(pdfFile.path, {
          'client_id': 'client-1',
          'start_date': DateTime(2026, 4, 13).toIso8601String(),
          'duration_years': '5',
          'warranty_card_number': 'WARR-001',
        }),
        throwsA(
          isA<ApiException>().having(
            (error) => error.toString(),
            'message',
            'Warranty upload rejected',
          ),
        ),
      );
    },
  );

  test('deleteWarranty sends version-bound confirmation and idempotency key',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? body;
    String? idempotencyKey;

    server.listen((request) async {
      expect(request.method, 'DELETE');
      expect(request.uri.path, '/api/warranty/warranty-1');
      idempotencyKey = request.headers.value('Idempotency-Key');
      body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'status': 'deleted',
        'warranty_id': 'warranty-1',
        'deletion_sequence': '42',
        'replayed': false,
      }));
      await request.response.close();
    });

    final apiService = ApiService(
      serverUrl: 'http://${server.address.host}:${server.port}',
    );
    final result = await apiService.deleteWarranty(
      id: 'warranty-1',
      warrantyCardNumber: 'CARD-1',
      warrantyVersion: 3,
      irreversibleConfirmation: 'PERMANENTLY DELETE WARRANTY CARD-1',
      idempotencyKey: 'delete-request-key-001',
    );

    expect(idempotencyKey, 'delete-request-key-001');
    expect(result['deletion_sequence'], '42');
    expect(body, {
      'confirmed_warranty_id': 'warranty-1',
      'confirmed_warranty_card_number': 'CARD-1',
      'confirmed_warranty_version': 3,
      'irreversible_confirmation': 'PERMANENTLY DELETE WARRANTY CARD-1',
    });
  });
}
