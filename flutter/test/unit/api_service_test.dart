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
}
